const std = @import("std");
const zap = @import("zap.zig");
const auth = @import("http_auth.zig");

// zap types
const Request = zap.Request;
const ListenerSettings = zap.HttpListenerSettings;
const Listener = zap.HttpListener;

/// Type of the request function callbacks.
pub const RequestFn = *const fn (self: *Endpoint, r: Request) void;

/// Settings to initialize an Endpoint
pub const EndpointSettings = struct {
    /// path / slug of the endpoint
    path: []const u8,
    /// callback to GET request handler
    get: ?RequestFn = null,
    /// callback to POST request handler
    post: ?RequestFn = null,
    /// callback to PUT request handler
    put: ?RequestFn = null,
    /// callback to DELETE request handler
    delete: ?RequestFn = null,
    /// callback to PATCH request handler
    patch: ?RequestFn = null,
    /// callback to OPTIONS request handler
    options: ?RequestFn = null,
    /// Only applicable to AuthenticatingEndpoint: handler for unauthorized requests
    unauthorized: ?RequestFn = null,
};

/// The simple Endpoint struct. Create one and pass in your callbacks. Then,
/// pass it to a HttpListener's `register()` function to register with the
/// listener.
///
/// **NOTE**: A common endpoint pattern for zap is to create your own struct
/// that embeds an Endpoint, provides specific callbacks, and uses
/// `@fieldParentPtr` to get a reference to itself.
///
/// Example:
/// A simple endpoint listening on the /stop route that shuts down zap.
/// The main thread usually continues at the instructions after the call to zap.start().
///
/// ```zig
/// // file: stopendpoint.zig
///
/// pub const Self = @This();
///
/// ep: zap.Endpoint = undefined,
///
/// pub fn init(
///     path: []const u8,
/// ) Self {
///     return .{
///         .ep = zap.Endpoint.init(.{
///             .path = path,
///             .get = get,
///         }),
///     };
/// }
///
/// // access the internal Endpoint
/// pub fn endpoint(self: *Self) *zap.Endpoint {
///     return &self.ep;
/// }
///
/// fn get(e: *zap.Endpoint, r: zap.Request) void {
///     const self: *Self = @fieldParentPtr(Self, "ep", e);
///     _ = self;
///     _ = e;
///     _ = r;
///     zap.stop();
/// }
/// ```
pub const Endpoint = struct {
    settings: EndpointSettings,

    const Self = @This();

    /// Initialize the endpoint.
    /// Set only the callbacks you need. Requests of HTTP methods without a
    /// provided callback will be ignored.
    pub fn init(s: EndpointSettings) Self {
        return .{
            .settings = .{
                .path = s.path,
                .get = s.get orelse &nop,
                .post = s.post orelse &nop,
                .put = s.put orelse &nop,
                .delete = s.delete orelse &nop,
                .patch = s.patch orelse &nop,
                .options = s.options orelse &nop,
                .unauthorized = s.unauthorized orelse &nop,
            },
        };
    }

    // no operation. Dummy handler function for ignoring unset request types.
    fn nop(self: *Endpoint, r: Request) void {
        _ = self;
        _ = r;
    }

    /// The global request handler for this Endpoint, called by the listener.
    pub fn onRequest(self: *Endpoint, r: zap.Request) void {
        if (r.method) |m| {
            if (std.mem.eql(u8, m, "GET"))
                return self.settings.get.?(self, r);
            if (std.mem.eql(u8, m, "POST"))
                return self.settings.post.?(self, r);
            if (std.mem.eql(u8, m, "PUT"))
                return self.settings.put.?(self, r);
            if (std.mem.eql(u8, m, "DELETE"))
                return self.settings.delete.?(self, r);
            if (std.mem.eql(u8, m, "PATCH"))
                return self.settings.patch.?(self, r);
            if (std.mem.eql(u8, m, "OPTIONS"))
                return self.settings.options.?(self, r);
        }
    }
};

/// Wrap an endpoint with an Authenticator -> new Endpoint of type Endpoint
/// is available via the `endpoint()` function.
pub fn AuthenticatingEndpoint(comptime Authenticator: type) type {
    return struct {
        authenticator: *Authenticator,
        ep: *Endpoint,
        auth_endpoint: Endpoint,
        const Self = @This();

        /// Init the authenticating endpoint. Pass in a pointer to the endpoint
        /// you want to wrap, and the Authenticator that takes care of authenticating
        /// requests.
        pub fn init(e: *Endpoint, authenticator: *Authenticator) Self {
            return .{
                .authenticator = authenticator,
                .ep = e,
                .auth_endpoint = Endpoint.init(.{
                    .path = e.settings.path,
                    // we override only the set ones. the other ones
                    // are set to null anyway -> will be nopped out
                    .get = if (e.settings.get != null) get else null,
                    .post = if (e.settings.post != null) post else null,
                    .put = if (e.settings.put != null) put else null,
                    .delete = if (e.settings.delete != null) delete else null,
                    .patch = if (e.settings.patch != null) patch else null,
                    .options = if (e.settings.options != null) options else null,
                    .unauthorized = e.settings.unauthorized,
                }),
            };
        }

        /// Get the auth endpoint struct of type Endpoint so it can be stored in the listener.
        /// When the listener calls the auth_endpoint, onRequest will have
        /// access to all of this via fieldParentPtr
        pub fn endpoint(self: *Self) *Endpoint {
            return &self.auth_endpoint;
        }

        /// GET: here, the auth_endpoint will be passed in as endpoint.
        /// Authenticates GET requests using the Authenticator.
        pub fn get(e: *Endpoint, r: zap.Request) void {
            const authEp: *Self = @fieldParentPtr(Self, "auth_endpoint", e);
            switch (authEp.authenticator.authenticateRequest(&r)) {
                .AuthFailed => {
                    if (e.settings.unauthorized) |unauthorized| {
                        unauthorized(authEp.ep, r);
                        return;
                    } else {
                        r.setStatus(.unauthorized);
                        r.sendBody("UNAUTHORIZED") catch return;
                        return;
                    }
                },
                .AuthOK => authEp.ep.settings.get.?(authEp.ep, r),
                .Handled => {},
            }
        }

        /// POST: here, the auth_endpoint will be passed in as endpoint.
        /// Authenticates POST requests using the Authenticator.
        pub fn post(e: *Endpoint, r: zap.Request) void {
            const authEp: *Self = @fieldParentPtr(Self, "auth_endpoint", e);
            switch (authEp.authenticator.authenticateRequest(&r)) {
                .AuthFailed => {
                    if (e.settings.unauthorized) |unauthorized| {
                        unauthorized(authEp.ep, r);
                        return;
                    } else {
                        r.setStatus(.unauthorized);
                        r.sendBody("UNAUTHORIZED") catch return;
                        return;
                    }
                },
                .AuthOK => authEp.ep.settings.post.?(authEp.ep, r),
                .Handled => {},
            }
        }

        /// PUT: here, the auth_endpoint will be passed in as endpoint.
        /// Authenticates PUT requests using the Authenticator.
        pub fn put(e: *Endpoint, r: zap.Request) void {
            const authEp: *Self = @fieldParentPtr(Self, "auth_endpoint", e);
            switch (authEp.authenticator.authenticateRequest(&r)) {
                .AuthFailed => {
                    if (e.settings.unauthorized) |unauthorized| {
                        unauthorized(authEp.ep, r);
                        return;
                    } else {
                        r.setStatus(.unauthorized);
                        r.sendBody("UNAUTHORIZED") catch return;
                        return;
                    }
                },
                .AuthOK => authEp.ep.settings.put.?(authEp.ep, r),
                .Handled => {},
            }
        }

        /// DELETE: here, the auth_endpoint will be passed in as endpoint.
        /// Authenticates DELETE requests using the Authenticator.
        pub fn delete(e: *Endpoint, r: zap.Request) void {
            const authEp: *Self = @fieldParentPtr(Self, "auth_endpoint", e);
            switch (authEp.authenticator.authenticateRequest(&r)) {
                .AuthFailed => {
                    if (e.settings.unauthorized) |unauthorized| {
                        unauthorized(authEp.ep, r);
                        return;
                    } else {
                        r.setStatus(.unauthorized);
                        r.sendBody("UNAUTHORIZED") catch return;
                        return;
                    }
                },
                .AuthOK => authEp.ep.settings.delete.?(authEp.ep, r),
                .Handled => {},
            }
        }

        /// PATCH: here, the auth_endpoint will be passed in as endpoint.
        /// Authenticates PATCH requests using the Authenticator.
        pub fn patch(e: *Endpoint, r: zap.Request) void {
            const authEp: *Self = @fieldParentPtr(Self, "auth_endpoint", e);
            switch (authEp.authenticator.authenticateRequest(&r)) {
                .AuthFailed => {
                    if (e.settings.unauthorized) |unauthorized| {
                        unauthorized(authEp.ep, r);
                        return;
                    } else {
                        r.setStatus(.unauthorized);
                        r.sendBody("UNAUTHORIZED") catch return;
                        return;
                    }
                },
                .AuthOK => authEp.ep.settings.patch.?(authEp.ep, r),
                .Handled => {},
            }
        }

        /// OPTIONS: here, the auth_endpoint will be passed in as endpoint.
        /// Authenticates OPTIONS requests using the Authenticator.
        pub fn options(e: *Endpoint, r: zap.Request) void {
            const authEp: *Self = @fieldParentPtr(Self, "auth_endpoint", e);
            switch (authEp.authenticator.authenticateRequest(&r)) {
                .AuthFailed => {
                    if (e.settings.unauthorized) |unauthorized| {
                        unauthorized(authEp.ep, r);
                        return;
                    } else {
                        r.setStatus(.unauthorized);
                        r.sendBody("UNAUTHORIZED") catch return;
                        return;
                    }
                },
                .AuthOK => authEp.ep.settings.put.?(authEp.ep, r),
                .Handled => {},
            }
        }
    };
}

pub const EndpointListenerError = error{
    /// Since we use .startsWith to check for matching paths, you cannot use
    /// endpoint paths that overlap at the beginning. --> When trying to register
    /// an endpoint whose path would shadow an already registered one, you will
    /// receive this error.
    EndpointPathShadowError,
};

/// The listener with ednpoint support
///
/// NOTE: It switches on path.startsWith -> so use endpoints with distinctly starting names!!
pub const EndpointListener = struct {
    listener: Listener,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Internal static struct of member endpoints
    var endpoints: std.ArrayList(*Endpoint) = undefined;

    /// Internal, static request handler callback. Will be set to the optional,
    /// user-defined request callback that only gets called if no endpoints match
    /// a request.
    var on_request: ?zap.HttpRequestFn = null;

    /// Initialize a new endpoint listener. Note, if you pass an `on_request`
    /// callback in the provided ListenerSettings, this request callback will be
    /// called every time a request arrives that no endpoint matches.
    pub fn init(a: std.mem.Allocator, l: ListenerSettings) Self {
        endpoints = std.ArrayList(*Endpoint).init(a);

        // take copy of listener settings before modifying the callback field
        var ls = l;

        // override the settings with our internal, actul callback function
        // so that "we" will be called on request
        ls.on_request = onRequest;

        // store the settings-provided request callback for later use
        on_request = l.on_request;
        return .{
            .listener = Listener.init(ls),
            .allocator = a,
        };
    }

    /// De-init the listener and free its resources.
    /// Registered endpoints will not be de-initialized automatically; just removed
    /// from the internal map.
    pub fn deinit(self: *Self) void {
        _ = self;
        endpoints.deinit();
    }

    /// Call this to start listening. After this, no more endpoints can be
    /// registered.
    pub fn listen(self: *Self) !void {
        try self.listener.listen();
    }

    /// Register an endpoint with this listener.
    /// NOTE: endpoint paths are matched with startsWith -> so use endpoints with distinctly starting names!!
    /// If you try to register an endpoint whose path would shadow an already registered one, you will
    /// receive an EndpointPathShadowError.
    pub fn register(self: *Self, e: *Endpoint) !void {
        _ = self;
        for (endpoints.items) |other| {
            if (std.mem.startsWith(
                u8,
                other.settings.path,
                e.settings.path,
            ) or std.mem.startsWith(
                u8,
                e.settings.path,
                other.settings.path,
            )) {
                return EndpointListenerError.EndpointPathShadowError;
            }
        }
        try endpoints.append(e);
    }

    fn onRequest(r: Request) void {
        if (r.path) |p| {
            for (endpoints.items) |e| {
                if (std.mem.startsWith(u8, p, e.settings.path)) {
                    e.onRequest(r);
                    return;
                }
            }
        }
        // if set, call the user-provided default callback
        if (on_request) |foo| {
            foo(r);
        }
    }
};
