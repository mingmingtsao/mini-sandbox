package protocol

import (
	"encoding/binary"
	"encoding/hex"
	"errors"
	"io"
	"strconv"
	"strings"
)

const MaximumBody = 4096
const BodySize = 34

type Frame struct {
	Kind         byte
	UUID         [16]byte
	Epoch, Nonce uint64
}

func Encode(f Frame) []byte {
	b := make([]byte, 38)
	binary.BigEndian.PutUint32(b, 34)
	b[4] = 1
	b[5] = f.Kind
	copy(b[6:22], f.UUID[:])
	binary.BigEndian.PutUint64(b[22:30], f.Epoch)
	binary.BigEndian.PutUint64(b[30:38], f.Nonce)
	return b
}
func Read(r io.Reader) (Frame, error) {
	var f Frame
	var h [4]byte
	if _, err := io.ReadFull(r, h[:]); err != nil {
		return f, err
	}
	size := binary.BigEndian.Uint32(h[:])
	if size > MaximumBody || size != BodySize {
		return f, errors.New("invalid body length")
	}
	var b [34]byte
	if _, err := io.ReadFull(r, b[:]); err != nil {
		return f, err
	}
	if b[0] != 1 || (b[1] != 1 && b[1] != 2) {
		return f, errors.New("unknown version/type")
	}
	f.Kind = b[1]
	copy(f.UUID[:], b[2:18])
	f.Epoch = binary.BigEndian.Uint64(b[18:26])
	f.Nonce = binary.BigEndian.Uint64(b[26:34])
	return f, nil
}
func Identity(cmdline string) ([16]byte, uint64, error) {
	var id [16]byte
	var epoch uint64
	seenID, seenEpoch := false, false
	for _, field := range strings.Fields(cmdline) {
		if strings.HasPrefix(field, "minisandbox.run_id=") {
			s := strings.TrimPrefix(field, "minisandbox.run_id=")
			if seenID || len(s) != 36 || s[8] != '-' || s[13] != '-' || s[18] != '-' || s[23] != '-' {
				return id, 0, errors.New("invalid UUID")
			}
			b, err := hex.DecodeString(strings.ReplaceAll(s, "-", ""))
			if err != nil || len(b) != 16 {
				return id, 0, errors.New("invalid UUID")
			}
			copy(id[:], b)
			seenID = true
		}
		if strings.HasPrefix(field, "minisandbox.epoch=") {
			s := strings.TrimPrefix(field, "minisandbox.epoch=")
			if seenEpoch || len(s) == 0 {
				return id, 0, errors.New("invalid epoch")
			}
			for _, c := range s {
				if c < '0' || c > '9' {
					return id, 0, errors.New("nondecimal epoch")
				}
			}
			n, err := strconv.ParseUint(s, 10, 64)
			if err != nil || n == 0 {
				return id, 0, errors.New("invalid epoch")
			}
			epoch = n
			seenEpoch = true
		}
	}
	if !seenID || !seenEpoch || id == [16]byte{} {
		return id, 0, errors.New("missing identity")
	}
	return id, epoch, nil
}
