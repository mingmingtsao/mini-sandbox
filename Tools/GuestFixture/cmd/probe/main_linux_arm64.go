//go:build linux && arm64

// This program is guest-only. It never accepts host environment or credentials.
package main

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	p "minisandbox/guest/protocol"
	"net"
	"os"
	"syscall"
	"time"
	"unsafe"
)

const deadline = 5 * time.Second

type socket struct {
	fd  int
	end time.Time
}

func (s *socket) wait(write bool) error {
	for {
		remaining := time.Until(s.end)
		if remaining <= 0 {
			return os.ErrDeadlineExceeded
		}
		var fds syscall.FdSet
		if s.fd < 0 || s.fd >= len(fds.Bits)*64 {
			return errors.New("descriptor outside select range")
		}
		fds.Bits[s.fd/64] |= 1 << uint(s.fd%64)
		tv := syscall.NsecToTimeval(remaining.Nanoseconds())
		var n int
		var err error
		if write {
			n, err = syscall.Select(s.fd+1, nil, &fds, nil, &tv)
		} else {
			n, err = syscall.Select(s.fd+1, &fds, nil, nil, &tv)
		}
		if err == syscall.EINTR {
			continue
		}
		if err != nil {
			return err
		}
		if n == 0 {
			return os.ErrDeadlineExceeded
		}
		return nil
	}
}
func (s *socket) Read(b []byte) (int, error) {
	for {
		if err := s.wait(false); err != nil {
			return 0, err
		}
		n, err := syscall.Read(s.fd, b)
		if err == syscall.EAGAIN || err == syscall.EINTR {
			continue
		}
		if n == 0 && err == nil {
			return 0, io.EOF
		}
		return n, err
	}
}
func (s *socket) Write(b []byte) (int, error) {
	total := 0
	for len(b) > 0 {
		if err := s.wait(true); err != nil {
			return total, err
		}
		n, err := syscall.Write(s.fd, b)
		if err == syscall.EAGAIN || err == syscall.EINTR {
			continue
		}
		if err != nil {
			return total, err
		}
		if n == 0 {
			return total, io.ErrShortWrite
		}
		total += n
		b = b[n:]
	}
	return total, nil
}
func (s *socket) Close() { syscall.Close(s.fd) }
func connect(port uint32) (*socket, error) {
	fd, err := syscall.Socket(40, syscall.SOCK_STREAM|syscall.SOCK_NONBLOCK|syscall.SOCK_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	s := &socket{fd: fd, end: time.Now().Add(deadline)}
	// Linux sockaddr_vm: family, reserved, port, CID, flags, padding.
	addr := struct {
		Family, Reserved uint16
		Port, CID        uint32
		Flags            byte
		Zero             [3]byte
	}{Family: 40, Port: port, CID: 2}
	_, _, errno := syscall.Syscall(syscall.SYS_CONNECT, uintptr(fd), uintptr(unsafe.Pointer(&addr)), unsafe.Sizeof(addr))
	if errno != 0 && errno != syscall.EINPROGRESS {
		s.Close()
		return nil, errno
	}
	if errno == syscall.EINPROGRESS {
		if err = s.wait(true); err != nil {
			s.Close()
			return nil, err
		}
		code, e := syscall.GetsockoptInt(fd, syscall.SOL_SOCKET, syscall.SO_ERROR)
		if e != nil {
			s.Close()
			return nil, e
		}
		if code != 0 {
			s.Close()
			return nil, syscall.Errno(code)
		}
	}
	return s, nil
}
func emit(v any) {
	b, err := json.Marshal(v)
	if err == nil && len(b) <= 49152 {
		fmt.Println(string(b))
	}
}
func text(path string) string {
	f, err := os.Open(path)
	if err != nil {
		return err.Error()
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, 4096))
	if err != nil {
		return err.Error()
	}
	return string(b)
}
func diagnostics() {
	files := map[string]string{}
	for _, path := range []string{"/proc/version", "/proc/sys/kernel/osrelease", "/proc/net/dev", "/proc/net/route", "/proc/net/ipv6_route", "/proc/mounts", "/proc/modules"} {
		files[path] = text(path)
	}
	interfaces := []string{}
	if all, err := net.Interfaces(); err != nil {
		interfaces = append(interfaces, err.Error())
	} else {
		for i, v := range all {
			if i >= 16 {
				break
			}
			interfaces = append(interfaces, fmt.Sprintf("%s flags=%s", v.Name, v.Flags))
		}
	}
	connects := map[string]string{}
	for family, target := range map[string]string{"tcp4": "192.0.2.1:9", "tcp6": "[2001:db8::1]:9"} {
		c, err := net.DialTimeout(family, target, time.Second)
		if err != nil {
			connects[family] = err.Error()
		} else {
			connects[family] = "connected"
			c.Close()
		}
	}
	emit(map[string]any{"event": "guestDiagnostic", "proc": files, "interfaces": interfaces, "connectResults": connects})
}
func attempt(label string, frame []byte, want *p.Frame) bool {
	s, err := connect(4050)
	if err != nil {
		emit(map[string]any{"event": label, "connectError": err.Error()})
		return false
	}
	defer s.Close()
	if _, err = s.Write(frame); err != nil {
		emit(map[string]any{"event": label, "writeError": err.Error()})
		return false
	}
	if want != nil {
		got, e := p.Read(s)
		ok := e == nil && got == *want
		report := map[string]any{"event": label, "matchedPong": ok}
		if e != nil {
			report["error"] = e.Error()
		}
		emit(report)
		return ok
	}
	var one [1]byte
	n, e := s.Read(one[:])
	report := map[string]any{"event": label, "receivedBytes": n, "closedWithoutResponse": n == 0 && (errors.Is(e, io.EOF) || errors.Is(e, syscall.ECONNRESET))}
	if e != nil {
		report["error"] = e.Error()
	}
	emit(report)
	return false
}
func main() {
	id, epoch, err := p.Identity(text("/proc/cmdline"))
	if err != nil {
		emit(map[string]any{"event": "fatal", "error": err.Error()})
		os.Exit(1)
	}
	f := p.Frame{Kind: 1, UUID: id, Epoch: epoch, Nonce: 1}
	want := f
	want.Kind = 2
	if !attempt("ping", p.Encode(f), &want) {
		os.Exit(1)
	}
	bad := f
	bad.Kind = 255
	attempt("unknownType", p.Encode(bad), nil)
	bad = f
	bad.UUID = [16]byte{}
	attempt("forgedUUID", p.Encode(bad), nil)
	header := make([]byte, 4)
	binary.BigEndian.PutUint32(header, 4097)
	attempt("oversizedHeader", header, nil)
	s, e := connect(4051)
	if e != nil {
		emit(map[string]any{"event": "unregisteredPort", "connectError": e.Error()})
	} else {
		s.Close()
		emit(map[string]any{"event": "unregisteredPort", "unexpectedConnection": true})
	}
	diagnostics()
	for i := 0; i < 32; i++ {
		time.Sleep(250 * time.Millisecond)
		f.Nonce++
		want = f
		want.Kind = 2
		if !attempt("awaitStop", p.Encode(f), &want) {
			break
		}
	}
}
