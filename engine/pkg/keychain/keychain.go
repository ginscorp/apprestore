// AppRestore deliberately links no macOS Keychain or file keyring implementation.
package keychain

type Keychain interface {
	Get(string) ([]byte, error)
	Set(string, []byte) error
	Remove(string) error
}
