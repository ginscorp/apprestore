package assets

import (
	"errors"
	"os"
)

func runtimeRoot() (string, error) {
	p := os.Getenv("APPRESTORE_RUNTIME")
	if p == "" {
		return "", errors.New("assets_missing")
	}
	return p, nil
}
