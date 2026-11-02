package main

import (
	"encoding/json"
	"errors"
	"net/http/cookiejar"
	"sync"
)

type memoryStore struct {
	mu   sync.Mutex
	data map[string][]byte
}

func newMemory() *memoryStore { return &memoryStore{data: make(map[string][]byte)} }
func (m *memoryStore) Get(k string) ([]byte, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	v, ok := m.data[k]
	if !ok {
		return nil, errors.New("not_authenticated")
	}
	return append([]byte(nil), v...), nil
}
func (m *memoryStore) Set(k string, v []byte) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if k == "account" {
		var fields map[string]any
		if err := json.Unmarshal(v, &fields); err != nil {
			return err
		}
		// Never retain the original password, including under a future JSON tag.
		delete(fields, "password")
		delete(fields, "Password")
		var err error
		v, err = json.Marshal(fields)
		if err != nil {
			return err
		}
	}
	if old := m.data[k]; old != nil {
		clear(old)
	}
	m.data[k] = append([]byte(nil), v...)
	return nil
}
func (m *memoryStore) Remove(k string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	clear(m.data[k])
	delete(m.data, k)
	return nil
}
func (m *memoryStore) Close() {
	m.mu.Lock()
	defer m.mu.Unlock()
	for k, v := range m.data {
		clear(v)
		delete(m.data, k)
	}
}

type memoryCookies struct{ *cookiejar.Jar }

func (m memoryCookies) Save() error { return nil }
