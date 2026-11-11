package main

import (
	"context"
	"github.com/majd/ipatool/v2/pkg/appstore"
	"testing"
)

type twoFactorStub struct {
	appstore.AppStore
	calls int
}

func (f *twoFactorStub) Login(q appstore.LoginInput) (appstore.LoginOutput, error) {
	f.calls++
	if q.AuthCode == "" {
		return appstore.LoginOutput{}, appstore.ErrAuthCodeRequired
	}
	return appstore.LoginOutput{Account: appstore.Account{Email: q.Email}}, nil
}

func TestTwoFactorKeepsOnlySameAccountDeviceState(t *testing.T) {
	mem := newMemory()
	_ = mem.Set("apprestore-store-device-v4", []byte("SYNTHETIC_DEVICE_STATE"))
	fake := &twoFactorStub{}
	s := &session{pendingAPI: fake, pendingStore: mem, pendingEmail: "example@example.invalid"}
	r := s.handle(context.Background(), request{Action: "login", Email: "example@example.invalid", Password: "SYNTHETIC_PASSWORD"})
	if r.Error != "two_factor_required" || s.pendingAPI != fake {
		t.Fatal("2FA discarded machine state")
	}
	r = s.handle(context.Background(), request{Action: "login", Email: "example@example.invalid", Password: "SYNTHETIC_PASSWORD", Code: "123456"})
	if !r.OK || fake.calls != 2 || s.api != fake || s.pendingAPI != nil {
		t.Fatal("2FA did not reuse the same client")
	}
	if err := s.close(); err != nil {
		t.Fatal(err)
	}
	if _, err := mem.Get("apprestore-store-device-v4"); err == nil {
		t.Fatal("device state survived logout")
	}
}

func TestCloseClearsPendingDeviceState(t *testing.T) {
	mem := newMemory()
	_ = mem.Set("apprestore-store-device-v4", []byte("SYNTHETIC_DEVICE_STATE"))
	s := &session{pendingAPI: &twoFactorStub{}, pendingStore: mem, pendingEmail: "example@example.invalid"}
	_ = s.close()
	if len(mem.data) != 0 || s.pendingAPI != nil || s.pendingEmail != "" {
		t.Fatal("pending authentication survived close")
	}
}
