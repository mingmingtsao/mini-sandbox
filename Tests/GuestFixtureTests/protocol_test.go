package guesttests

import (
	"bytes"
	"encoding/hex"
	p "minisandbox/guest/protocol"
	"testing"
)

func TestGolden(t *testing.T) {
	id, epoch, err := p.Identity("console=hvc0 minisandbox.run_id=00010203-0405-0607-0809-0a0b0c0d0e0f minisandbox.epoch=1")
	if err != nil {
		t.Fatal(err)
	}
	f := p.Frame{Kind: 1, UUID: id, Epoch: epoch, Nonce: 9}
	got := p.Encode(f)
	if hex.EncodeToString(got) != "000000220101000102030405060708090a0b0c0d0e0f00000000000000010000000000000009" {
		t.Fatalf("golden mismatch: %x", got)
	}
	read, err := p.Read(bytes.NewReader(got))
	if err != nil || read != f {
		t.Fatalf("roundtrip %v %v", read, err)
	}
}
func TestMalformed(t *testing.T) {
	for _, raw := range [][]byte{nil, {0, 0, 16, 1}, {0, 0, 0, 33}, {0, 0, 0, 34, 1}, append([]byte{0, 0, 0, 34}, make([]byte, 34)...)} {
		if _, err := p.Read(bytes.NewReader(raw)); err == nil {
			t.Fatalf("accepted %x", raw)
		}
	}
	f := p.Frame{Kind: 255}
	if _, err := p.Read(bytes.NewReader(p.Encode(f))); err == nil {
		t.Fatal("unknown type accepted")
	}
}
func TestIdentityRejectsAmbiguity(t *testing.T) {
	for _, s := range []string{"", "minisandbox.run_id=bad minisandbox.epoch=1", "minisandbox.run_id=00000000-0000-0000-0000-000000000000 minisandbox.epoch=1", "minisandbox.run_id=00010203-0405-0607-0809-0a0b0c0d0e0f minisandbox.epoch=0", "minisandbox.run_id=00010203-0405-0607-0809-0a0b0c0d0e0f minisandbox.epoch=1 minisandbox.epoch=2"} {
		if _, _, err := p.Identity(s); err == nil {
			t.Fatalf("accepted %q", s)
		}
	}
}
