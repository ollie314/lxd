package main

import (
	"fmt"
	"io/ioutil"

	"github.com/chai2010/gettext-go/gettext"

	"github.com/lxc/lxd"
	"github.com/lxc/lxd/shared/gnuflag"
)

type infoCmd struct {
	showLog bool
}

func (c *infoCmd) showByDefault() bool {
	return true
}

func (c *infoCmd) usage() string {
	return gettext.Gettext(
		`List information on containers.

This will support remotes and images as well, but only containers for now.

lxc info [<remote>:]container [--show-log]`)
}

func (c *infoCmd) flags() {
	gnuflag.BoolVar(&c.showLog, "show-log", false, gettext.Gettext("Show the container's last 100 log lines?"))
}

func (c *infoCmd) run(config *lxd.Config, args []string) error {
	var remote string
	var cName string
	if len(args) == 1 {
		remote, cName = config.ParseRemoteAndContainer(args[0])
	} else {
		remote, cName = config.ParseRemoteAndContainer("")
	}
	if cName == "" {
		fmt.Println(gettext.Gettext("Information about remotes not yet supported"))
		return errArgs
	}

	d, err := lxd.NewClient(config, remote)
	if err != nil {
		return err
	}
	ct, err := d.ContainerStatus(cName)
	if err != nil {
		return err
	}

	fmt.Printf(gettext.Gettext("Name: %s")+"\n", ct.Name)
	fmt.Printf(gettext.Gettext("Status: %s")+"\n", ct.Status.Status)
	if ct.Status.Init != 0 {
		fmt.Printf(gettext.Gettext("Init: %d")+"\n", ct.Status.Init)
		fmt.Printf(gettext.Gettext("Ips:") + "\n")
		foundone := false
		for _, ip := range ct.Status.Ips {
			vethStr := ""
			if ip.HostVeth != "" {
				vethStr = fmt.Sprintf("\t%s", ip.HostVeth)
			}

			fmt.Printf("  %s:\t%s\t%s%s\n", ip.Interface, ip.Protocol, ip.Address, vethStr)
			foundone = true
		}
		if !foundone {
			fmt.Println(gettext.Gettext("(none)"))
		}
	}

	// List snapshots
	first_snapshot := true
	snaps, err := d.ListSnapshots(cName)
	if err != nil {
		return nil
	}
	for _, snap := range snaps {
		if first_snapshot {
			fmt.Println(gettext.Gettext("Snapshots:"))
		}
		fmt.Printf("  %s\n", snap)
		first_snapshot = false
	}

	if c.showLog {
		log, err := d.GetLog(cName, "lxc.log")
		if err != nil {
			return err
		}

		stuff, err := ioutil.ReadAll(log)
		if err != nil {
			return err
		}

		fmt.Printf("\n"+gettext.Gettext("Log:")+"\n\n%s\n", string(stuff))
	}

	return nil
}
