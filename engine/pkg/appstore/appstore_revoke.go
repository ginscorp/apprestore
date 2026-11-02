package appstore

// AppRestore only clears its injected in-memory store. This is not server revocation.
func(t *appstore)Revoke()error{return t.keychain.Remove("account")}
