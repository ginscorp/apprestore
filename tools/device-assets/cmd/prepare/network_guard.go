package main

import (
	"errors"
	"io"
	"net/http"
	"sync"
)

// appleOnlyTransport is an experimental guard for explicitly requested public
// Apple image access. It handles no account credentials and enforces a shared
// body-byte budget across all requests.
type appleOnlyTransport struct {
	next  http.RoundTripper
	mu    sync.Mutex
	used  int64
	limit int64
}

func (t *appleOnlyTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	if r == nil || r.URL == nil || r.URL.Scheme != "https" || r.URL.User != nil || (r.URL.Port() != "" && r.URL.Port() != "443") {
		return nil, errors.New("asset destination blocked")
	}
	switch r.URL.Hostname() {
	case "updates.cdn-apple.com", "wkms-public.apple.com", "fcs-keys-pub-prod.cdn-apple.com":
	default:
		return nil, errors.New("asset destination blocked")
	}
	response, err := t.next.RoundTrip(r)
	if err != nil {
		return response, err
	}
	if response == nil || response.Body == nil {
		return nil, errors.New("empty asset response")
	}
	response.Body = &budgetedBody{ReadCloser: response.Body, owner: t}
	return response, nil
}

type budgetedBody struct {
	io.ReadCloser
	owner *appleOnlyTransport
}

func (b *budgetedBody) Read(data []byte) (int, error) {
	if len(data) == 0 {
		return 0, nil
	}
	b.owner.mu.Lock()
	defer b.owner.mu.Unlock()
	remaining := b.owner.limit - b.owner.used
	if remaining <= 0 {
		return 0, errors.New("asset transfer budget exhausted")
	}
	if int64(len(data)) > remaining {
		data = data[:int(remaining)]
	}
	n, err := b.ReadCloser.Read(data)
	b.owner.used += int64(n)
	return n, err
}
