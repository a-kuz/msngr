/// Wire protocol version of this build.
///
/// The client states its version in the socket upgrade (`/ws?v=`), the server
/// states both numbers back in `hello` and in `GET /api/version`. A client
/// below the floor is refused at the upgrade with `client_too_old` and a 426,
/// so an app that can no longer be served says so instead of reconnecting into
/// silence.
///
/// There is no backward compatibility to preserve (see docs/PROCESS.md): the
/// floor moves up with the version whenever a frame changes shape. What the
/// numbers buy is the branch — the moment a change is worth carrying both
/// sides of, the floor stays behind and the version tells the server which
/// shape the socket in front of it speaks.
export const PROTOCOL_VERSION = 1;

/// Oldest client version this build still serves.
export const MIN_CLIENT_PROTOCOL = 1;
