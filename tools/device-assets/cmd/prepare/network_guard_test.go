package main

import (
	"bytes"
	"errors"
	"io"
	"net/http"
	"testing"
)

type fakeTransport struct{ calls int }

func (f *fakeTransport) RoundTrip(*http.Request) (*http.Response, error) {
	f.calls++
	return &http.Response{StatusCode: 200, Body: io.NopCloser(bytes.NewReader([]byte("synthetic")))}, nil
}

func TestSyntheticAppleDestinationAndBudgetGuard(t *testing.T) {
	fake := &fakeTransport{}
	guard := &appleOnlyTransport{next: fake, limit: 5}
	for _, raw := range []string{"http://updates.cdn-apple.com/a", "https://updates.cdn-apple.com.evil.invalid/a", "https://user:pass@updates.cdn-apple.com/a", "https://updates.cdn-apple.com:444/a", "https://example.invalid/a"} {
		r, _ := http.NewRequest("GET", raw, nil)
		if _, err := guard.RoundTrip(r); err == nil {
			t.Fatal("unsafe endpoint accepted")
		}
	}
	if fake.calls != 0 {
		t.Fatal("blocked endpoint reached transport")
	}
	r, _ := http.NewRequest("GET", "https://updates.cdn-apple.com:443/a", nil)
	response, err := guard.RoundTrip(r)
	if err != nil {
		t.Fatal(err)
	}
	data := make([]byte, 8)
	n, err := io.ReadFull(response.Body, data)
	if n != 5 || err == nil || guard.used != 5 || !bytes.Equal(data[:n], []byte("synth")) {
		t.Fatal("byte limit was not enforced")
	}
	_, err = response.Body.Read(make([]byte, 1))
	if err == nil || errors.Is(err, io.EOF) {
		t.Fatal("exhausted budget accepted")
	}
	_ = response.Body.Close()
}
