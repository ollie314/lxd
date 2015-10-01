package main

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"os"

	"github.com/mattn/go-sqlite3"

	"github.com/lxc/lxd"
	"github.com/lxc/lxd/shared"
)

type resp struct {
	Type       lxd.ResponseType  `json:"type"`
	Status     string            `json:"status"`
	StatusCode shared.StatusCode `json:"status_code"`
	Metadata   interface{}       `json:"metadata"`
}

type Response interface {
	Render(w http.ResponseWriter) error
}

type syncResponse struct {
	success  bool
	metadata interface{}
}

/*
  fname: name of the file without path
  headers: any other headers that should be set in the response
*/

type fileResponseEntry struct {
	identifier string
	path       string
	filename   string
}

type fileResponse struct {
	req              *http.Request
	files            []fileResponseEntry
	headers          map[string]string
	removeAfterServe bool
}

func FileResponse(r *http.Request, files []fileResponseEntry, headers map[string]string, removeAfterServe bool) Response {
	return &fileResponse{r, files, headers, removeAfterServe}
}

func (r *fileResponse) Render(w http.ResponseWriter) error {
	if r.headers != nil {
		for k, v := range r.headers {
			w.Header().Set(k, v)
		}
	}

	// No file, well, it's easy then
	if len(r.files) == 0 {
		return nil
	}

	// For a single file, return it inline
	if len(r.files) == 1 {
		w.Header().Set("Content-Type", "application/octet-stream")
		w.Header().Set("Content-Disposition", fmt.Sprintf("inline;filename=%s", r.files[0].filename))

		f, err := os.Open(r.files[0].path)
		if err != nil {
			return err
		}
		defer f.Close()

		fi, err := f.Stat()
		if err != nil {
			return err
		}

		http.ServeContent(w, r.req, r.files[0].filename, fi.ModTime(), f)
		if r.removeAfterServe {
			os.Remove(r.files[0].filename)
		}

		return nil
	}

	// Now the complex multipart answer
	body := &bytes.Buffer{}
	mw := multipart.NewWriter(body)

	for _, entry := range r.files {
		fd, err := os.Open(entry.path)
		if err != nil {
			return err
		}
		defer fd.Close()

		fw, err := mw.CreateFormFile(entry.identifier, entry.filename)
		if err != nil {
			return err
		}

		_, err = io.Copy(fw, fd)
		if err != nil {
			return err
		}
	}

	mw.Close()
	w.Header().Set("Content-Type", mw.FormDataContentType())
	_, err := io.Copy(w, body)
	return err
}

func WriteJSON(w http.ResponseWriter, body interface{}) error {
	var output io.Writer
	var captured *bytes.Buffer

	output = w
	if *debug {
		captured = &bytes.Buffer{}
		output = io.MultiWriter(w, captured)
	}

	err := json.NewEncoder(output).Encode(body)

	if captured != nil {
		shared.DebugJson(captured)
	}

	return err
}

func (r *syncResponse) Render(w http.ResponseWriter) error {
	status := shared.Success
	if !r.success {
		status = shared.Failure
	}

	resp := resp{Type: lxd.Sync, Status: status.String(), StatusCode: status, Metadata: r.metadata}
	return WriteJSON(w, resp)
}

/*
 * This function and AsyncResponse are simply wrappers for the response so
 * users don't have to remember whether to use {}s or ()s when building
 * responses.
 */
func SyncResponse(success bool, metadata interface{}) Response {
	return &syncResponse{success, metadata}
}

var EmptySyncResponse = &syncResponse{true, make(map[string]interface{})}

type async struct {
	Type       lxd.ResponseType    `json:"type"`
	Status     string              `json:"status"`
	StatusCode shared.StatusCode   `json:"status_code"`
	Operation  string              `json:"operation"`
	Resources  map[string][]string `json:"resources"`
	Metadata   interface{}         `json:"metadata"`
}

type asyncResponse struct {
	run       func() shared.OperationResult
	cancel    func() error
	ws        shared.OperationWebsocket
	resources map[string][]string
	metadata  shared.Jmap
	done      chan shared.OperationResult
}

func (r *asyncResponse) Render(w http.ResponseWriter) error {
	op, err := createOperation(r.metadata, r.resources, r.run, r.cancel, r.ws)
	if err != nil {
		return err
	}

	err = startOperation(op)
	if err != nil {
		return err
	}

	body := async{Type: lxd.Async, Status: shared.OK.String(), StatusCode: shared.OK, Operation: op}
	if r.ws != nil {
		body.Metadata = r.ws.Metadata()
	} else if r.metadata != nil {
		body.Metadata = r.metadata
	}

	if r.resources != nil {
		resources := make(map[string][]string)
		for key, value := range r.resources {
			var values []string
			for _, c := range value {
				values = append(values, fmt.Sprintf("/%s/%s/%s", shared.APIVersion, key, c))
			}
			resources[key] = values
		}
		body.Resources = resources
	}

	w.Header().Set("Location", op)
	w.WriteHeader(202)

	return WriteJSON(w, body)
}

func AsyncResponse(run func() shared.OperationResult, cancel func() error) Response {
	return &asyncResponse{run: run, cancel: cancel}
}

func AsyncResponseWithWs(ws shared.OperationWebsocket, cancel func() error) Response {
	return &asyncResponse{run: ws.Do, cancel: cancel, ws: ws}
}

type ErrorResponse struct {
	code int
	msg  string
}

func (r *ErrorResponse) Render(w http.ResponseWriter) error {
	var output io.Writer

	buf := &bytes.Buffer{}
	output = buf
	var captured *bytes.Buffer
	if *debug {
		captured = &bytes.Buffer{}
		output = io.MultiWriter(buf, captured)
	}

	err := json.NewEncoder(output).Encode(shared.Jmap{"type": lxd.Error, "error": r.msg, "error_code": r.code})

	if err != nil {
		return err
	}

	if *debug {
		shared.DebugJson(captured)
	}
	http.Error(w, buf.String(), r.code)
	return nil
}

/* Some standard responses */
var NotImplemented = &ErrorResponse{http.StatusNotImplemented, "not implemented"}
var NotFound = &ErrorResponse{http.StatusNotFound, "not found"}
var Forbidden = &ErrorResponse{http.StatusForbidden, "not authorized"}
var Conflict = &ErrorResponse{http.StatusConflict, "already exists"}

func BadRequest(err error) Response {
	return &ErrorResponse{http.StatusBadRequest, err.Error()}
}

func InternalError(err error) Response {
	return &ErrorResponse{http.StatusInternalServerError, err.Error()}
}

/*
 * SmartError returns the right error message based on err.
 */
func SmartError(err error) Response {
	switch err {
	case nil:
		return EmptySyncResponse
	case os.ErrNotExist:
		return NotFound
	case sql.ErrNoRows:
		return NotFound
	case NoSuchObjectError:
		return NotFound
	case os.ErrPermission:
		return Forbidden
	case DbErrAlreadyDefined:
		return Conflict
	case sqlite3.ErrConstraintUnique:
		return Conflict
	default:
		return InternalError(err)
	}
}
