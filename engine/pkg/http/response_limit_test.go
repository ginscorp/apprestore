package http

import (
	"errors"
	"io"
	"net/http"
	"net/url"
	"strings"
	"testing"
)

func TestRateLimitKeepsStatusWithoutResponseBody(t *testing.T) {
	c := &client[any]{}
	_, err := c.handleXMLResponse(&http.Response{StatusCode: 429, Header: http.Header{}, Body: io.NopCloser(strings.NewReader("PRIVATE_CANARY_RESPONSE"))})
	var response *UnexpectedResponseError
	if !errors.As(err, &response) || response.StatusCode != 429 || strings.Contains(err.Error(), "CANARY") {
		t.Fatal("unsafe or unclassified rate limit")
	}
}

func TestBoundedResponse(t *testing.T) {
	if _, e := readResponseBody(strings.NewReader(strings.Repeat("x", 16*1024*1024+1))); e == nil {
		t.Fatal("unbounded response")
	}
	if b, e := readResponseBody(strings.NewReader("ok")); e != nil || string(b) != "ok" {
		t.Fatal("normal response rejected")
	}
}
func TestRedirectBound(t *testing.T) {
	c := NewClient[any](Args{}).(*client[any])
	u, _ := url.Parse("https://a.apple.com/fixture")
	r := &http.Request{URL: u}
	via := make([]*http.Request, 10)
	for i := range via {
		via[i] = r
	}
	if c.internalClient.CheckRedirect(r, via) == nil {
		t.Fatal("redirect loop accepted")
	}
}
