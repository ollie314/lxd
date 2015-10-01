package main

import (
	"fmt"
	"net"
	"net/url"
	"os"
	"strings"
	"syscall"

	"github.com/chai2010/gettext-go/gettext"

	"github.com/lxc/lxd"
	"github.com/lxc/lxd/shared"
	"github.com/lxc/lxd/shared/gnuflag"
)

func main() {
	if err := run(); err != nil {
		// The action we take depends on the error we get.
		msg := fmt.Sprintf(gettext.Gettext("error: %v"), err)
		switch t := err.(type) {
		case *url.Error:
			switch u := t.Err.(type) {
			case *net.OpError:
				if u.Op == "dial" && u.Net == "unix" {
					switch errno := u.Err.(type) {
					case syscall.Errno:
						switch errno {
						case syscall.ENOENT:
							msg = gettext.Gettext("LXD socket not found; is LXD running?")
						case syscall.ECONNREFUSED:
							msg = gettext.Gettext("Connection refused; is LXD running?")
						case syscall.EACCES:
							msg = gettext.Gettext("Permisson denied, are you in the lxd group?")
						default:
							msg = fmt.Sprintf("%d %s", uintptr(errno), errno.Error())
						}
					}
				}
			}
		}

		fmt.Fprintln(os.Stderr, fmt.Sprintf("%s", msg))
		os.Exit(1)
	}
}

func run() error {
	gettext.BindTextdomain("lxd", "", nil)
	gettext.Textdomain("lxd")

	verbose := gnuflag.Bool("verbose", false, gettext.Gettext("Enables verbose mode."))
	debug := gnuflag.Bool("debug", false, gettext.Gettext("Enables debug mode."))
	forceLocal := gnuflag.Bool("force-local", false, gettext.Gettext("Force using the local unix socket."))

	gnuflag.StringVar(&lxd.ConfigDir, "config", lxd.ConfigDir, gettext.Gettext("Alternate config directory."))

	if len(os.Args) >= 3 && os.Args[1] == "config" && os.Args[2] == "profile" {
		fmt.Fprintf(os.Stderr, gettext.Gettext("`lxc config profile` is deprecated, please use `lxc profile`")+"\n")
		os.Args = append(os.Args[:1], os.Args[2:]...)
	}

	if len(os.Args) >= 2 && (os.Args[1] == "-h" || os.Args[1] == "--help") {
		os.Args[1] = "help"
	}

	if len(os.Args) >= 2 && (os.Args[1] == "--all") {
		os.Args[1] = "help"
		os.Args = append(os.Args, "--all")
	}

	if len(os.Args) == 2 && os.Args[1] == "--version" {
		os.Args[1] = "version"
	}

	if len(os.Args) < 2 {
		commands["help"].run(nil, nil)
		os.Exit(1)
	}
	name := os.Args[1]
	cmd, ok := commands[name]
	if !ok {
		fmt.Fprintf(os.Stderr, gettext.Gettext("error: unknown command: %s")+"\n", name)
		commands["help"].run(nil, nil)
		os.Exit(1)
	}
	cmd.flags()
	gnuflag.Usage = func() {
		fmt.Fprintf(os.Stderr, gettext.Gettext("Usage: %s")+"\n\n"+gettext.Gettext("Options:")+"\n\n", strings.TrimSpace(cmd.usage()))
		gnuflag.PrintDefaults()
	}

	os.Args = os.Args[1:]
	gnuflag.Parse(true)

	shared.SetLogger("", "", *verbose, *debug)

	var config *lxd.Config
	var err error

	if *forceLocal {
		config = &lxd.DefaultConfig
	} else {
		config, err = lxd.LoadConfig()
		if err != nil {
			return err
		}
	}

	certf := lxd.ConfigPath("client.crt")
	keyf := lxd.ConfigPath("client.key")

	if !*forceLocal && os.Args[0] != "help" && os.Args[0] != "version" && (!shared.PathExists(certf) || !shared.PathExists(keyf)) {
		fmt.Fprintf(os.Stderr, gettext.Gettext("Generating a client certificate. This may take a minute...")+"\n")

		err = shared.FindOrGenCert(certf, keyf)
		if err != nil {
			return err
		}

		fmt.Fprintf(os.Stderr, gettext.Gettext("If this is your first run, you will need to import images using the 'lxd-images' script.")+"\n")
		fmt.Fprintf(os.Stderr, gettext.Gettext("For example: 'lxd-images import ubuntu --alias ubuntu'.")+"\n")
	}

	err = cmd.run(config, gnuflag.Args())
	if err == errArgs {
		fmt.Fprintf(os.Stderr, gettext.Gettext("error: %v")+"\n%s\n", err, cmd.usage())
		os.Exit(1)
	}
	return err
}

type command interface {
	usage() string
	flags()
	showByDefault() bool
	run(config *lxd.Config, args []string) error
}

var commands = map[string]command{
	"config":   &configCmd{},
	"copy":     &copyCmd{},
	"delete":   &deleteCmd{},
	"exec":     &execCmd{},
	"file":     &fileCmd{},
	"finger":   &fingerCmd{},
	"help":     &helpCmd{},
	"image":    &imageCmd{},
	"info":     &infoCmd{},
	"init":     &initCmd{},
	"launch":   &launchCmd{},
	"list":     &listCmd{},
	"move":     &moveCmd{},
	"profile":  &profileCmd{},
	"publish":  &publishCmd{},
	"remote":   &remoteCmd{},
	"restart":  &actionCmd{shared.Restart, true},
	"restore":  &restoreCmd{},
	"snapshot": &snapshotCmd{},
	"start":    &actionCmd{shared.Start, false},
	"stop":     &actionCmd{shared.Stop, true},
	"version":  &versionCmd{},
}

var errArgs = fmt.Errorf(gettext.Gettext("wrong number of subcommand arguments"))
