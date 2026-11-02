// Package netguard restricts authenticated traffic to Apple's HTTPS services.
package netguard

import (
	"errors"
	"net/http"
	"strings"
)

type Transport struct{ Next http.RoundTripper }

func AppleHost(host string) bool {
	host = strings.ToLower(host)
	for _, domain := range []string{"apple.com", "itunes.com", "mzstatic.com"} {
		if host == domain || strings.HasSuffix(host, "."+domain) {
			return true
		}
	}
	return false
}

func (t Transport) RoundTrip(r *http.Request) (*http.Response, error) {
	if r.URL.Scheme != "https" || r.URL.User != nil || (r.URL.Port() != "" && r.URL.Port() != "443") || !AppleHost(r.URL.Hostname()) {
		return nil, errors.New("destination_blocked")
	}
	res, err := t.Next.RoundTrip(r)
	status := 0
	if res != nil {
		status = res.StatusCode
	}
	RecordTrace(r.URL.Path, status, err != nil)
	return res, err
}

func Base() *http.Transport {
	transport := http.DefaultTransport
	if guarded, ok := transport.(Transport); ok {
		transport = guarded.Next
	}
	base := transport.(*http.Transport).Clone()
	base.Proxy = nil
	return base
}

func Isolated() http.RoundTripper {
	base := Base()
	base.DisableKeepAlives = true
	return Transport{Next: base}
}
