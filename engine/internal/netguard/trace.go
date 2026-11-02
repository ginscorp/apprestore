package netguard

import (
	"fmt"
	"runtime"
	"strings"
	"sync"
)

// A bounded, opt-in trace of code paths/statuses. Never retains requests, bodies,
// full URLs, headers, cookies, account identifiers or error strings.
type TraceEvent struct {
	Step   string   `json:"step"`
	Status int      `json:"http_status,omitempty"`
	Result string   `json:"result"`
	Frames []string `json:"code_stack,omitempty"`
}

var traceState struct {
	sync.Mutex
	active bool
	events []TraceEvent
}

func BeginTrace() {
	traceState.Lock()
	defer traceState.Unlock()
	traceState.active = true
	traceState.events = nil
}
func EndTrace() []TraceEvent {
	traceState.Lock()
	defer traceState.Unlock()
	v := traceState.events
	traceState.active = false
	traceState.events = nil
	return v
}
func RecordTrace(path string, status int, failed bool) {
	traceState.Lock()
	defer traceState.Unlock()
	if !traceState.active || len(traceState.events) >= 40 {
		return
	}
	step := "apple_other"
	for fragment, label := range map[string]string{"/bag": "service_endpoints", "/volumeStoreDownloadProduct": "legacy_download", "/redownload": "redownload", "/updateProduct": "update_product", "/ent/download": "ent_download", "/lookup": "public_lookup"} {
		if strings.Contains(path, fragment) {
			step = label
			break
		}
	}
	result := "response"
	if failed {
		result = "transport_error"
	}
	pcs := make([]uintptr, 28)
	n := runtime.Callers(3, pcs)
	frames := runtime.CallersFrames(pcs[:n])
	var stack []string
	for {
		frame, more := frames.Next()
		if strings.Contains(frame.Function, "github.com/majd/ipatool/v2/pkg/") {
			parts := strings.Split(frame.Function, "/")
			stack = append(stack, fmt.Sprintf("%s:%d", strings.Join(parts[len(parts)-2:], "/"), frame.Line))
		}
		if !more || len(stack) >= 8 {
			break
		}
	}
	traceState.events = append(traceState.events, TraceEvent{Step: step, Status: status, Result: result, Frames: stack})
}
