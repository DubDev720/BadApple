package ipc

import (
	"encoding/json"
	"fmt"
	"net"
)

func Send(path string, msg any) error {
	conn, err := net.Dial("unix", path)
	if err != nil {
		return err
	}
	defer conn.Close()
	return json.NewEncoder(conn).Encode(msg)
}

func Request(path string, req any, resp any) error {
	conn, err := net.Dial("unix", path)
	if err != nil {
		return err
	}
	defer conn.Close()

	if err := json.NewEncoder(conn).Encode(req); err != nil {
		return fmt.Errorf("encode request: %w", err)
	}
	if err := json.NewDecoder(conn).Decode(resp); err != nil {
		return fmt.Errorf("decode response: %w", err)
	}
	return nil
}
