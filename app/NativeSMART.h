// Use the SDK's complete 512-byte SMART ABI, not a copied packed structure.
#include <IOKit/storage/nvme/NVMeSMARTLibExternal.h>
static inline CFUUIDRef ARNVMeClientID(void) { return kIONVMeSMARTUserClientTypeID; }
static inline CFUUIDRef ARNVMeInterfaceID(void) { return kIONVMeSMARTInterfaceID; }
static inline CFUUIDRef ARPluginInterfaceID(void) { return kIOCFPlugInInterfaceID; }
