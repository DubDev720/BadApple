package ipc

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
)

func ListenUnix(path string) (net.Listener, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o750); err != nil {
		return nil, fmt.Errorf("create socket dir: %w", err)
	}
	_ = os.Remove(path)
	ln, err := net.Listen("unix", path)
	if err != nil {
		return nil, err
	}
	if err := os.Chmod(path, 0o660); err != nil {
		ln.Close()
		return nil, err
	}
	return ln, nil
}

func DecodeJSON(conn net.Conn, v any) error {
	defer conn.Close()
	return json.NewDecoder(conn).Decode(v)
}

func EncodeJSON(conn net.Conn, v any) error {
	defer conn.Close()
	return json.NewEncoder(conn).Encode(v)
}
