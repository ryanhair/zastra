//! Root of the C library built by `z.addCLib`: exports `<name>_*` and
//! `zastra_*` functions for the App in the "app" module.

const z = @import("zastra");
const app = @import("app");
const options = @import("zastra_clib_options");

comptime {
    if (!@hasDecl(app, "App")) @compileError("zastra C library: the app module must export `pub const App = z.App(...)`");
    z.capi.exportAll(app.App, app, options.name);
}
