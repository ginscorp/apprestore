package appstore

import "testing"

func TestAppRestoreNativeEndpointValidation(t *testing.T) {
	for _, u := range []string{"https://auth.itunes.apple.com/auth/v1/native", "https://auth.itunes.apple.com/auth/v1/native/fast/", "https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate/"} {
		if err := validateAuthenticationEndpoint(u); err != nil {
			t.Fatal(err)
		}
	}
	for _, u := range []string{"https://auth.itunes.apple.com.evil.invalid/auth/v1/native", "http://auth.itunes.apple.com/auth/v1/native", "https://auth.itunes.apple.com/other", "https://user:pass@auth.itunes.apple.com/auth/v1/native"} {
		if validateAuthenticationEndpoint(u) == nil {
			t.Fatal("untrusted destination accepted")
		}
	}
	r := (&appstore{}).loginRequest("example@example.invalid", "synthetic", "", "000000000001", "https://auth.itunes.apple.com/auth/v1/native", 1, nil)
	if r.Headers["Content-Type"] != "application/x-apple-plist" || r.Headers["User-Agent"] != storeAuthenticationUserAgent || !r.NoRedirects {
		t.Fatal("wrong native request format")
	}
	if authenticationResponseDSID(map[string]string{"x-dsid": "12345"}) != "12345" {
		t.Fatal("DSID header")
	}
	if authenticationResponseDSID(map[string]string{"Set-Cookie": "mz_at0-12345=synthetic; Path=/"}) != "12345" {
		t.Fatal("DSID cookie")
	}
}
