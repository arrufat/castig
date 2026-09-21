//! UPnP AV: driving a MediaRenderer over SOAP, and finding one over SSDP.
//!
//! The model is the same as Cast's: the renderer is handed a URL and pulls
//! the bytes back over HTTP with Range. What differs is that there is no
//! app to launch, no pushed status, and no agreement between renderers
//! about anything that is not in the specification.

/// SSDP discovery and the device description.
pub const ssdp = @import("dlna/ssdp.zig");

test {
    _ = ssdp;
}
