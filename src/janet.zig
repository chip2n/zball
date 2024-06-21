const janet = @import("cjanet");

pub const JanetTable = janet.JanetTable;
pub const JanetSymbol = janet.JanetSymbol;
pub const JanetFunction = janet.JanetFunction;
pub const Janet = janet.Janet;
pub const init = janet.janet_init;
pub const deinit = janet.janet_deinit;
pub const core_env = janet.janet_core_env;
pub const env_lookup = janet.janet_env_lookup;
pub const gclock = janet.janet_gclock;
pub const gcunlock = janet.janet_gcunlock;
pub const unmarshal = janet.janet_unmarshal;
pub const wrap_keyword = janet.janet_wrap_keyword;
pub const wrap_nil = janet.janet_wrap_nil;
pub const unwrap_table = janet.janet_unwrap_table;
pub const unwrap_function = janet.janet_unwrap_function;
pub const checktype = janet.janet_checktype;
pub const to_string = janet.janet_to_string;
pub const ckeywordv = janet.janet_ckeywordv;
pub const ckeyword = janet.janet_ckeyword;
pub const csymbol = janet.janet_csymbol;

pub const table_find = janet.janet_table_find;
pub const table_get = janet.janet_table_get;

pub const fiber = janet.janet_fiber;

pub const stacktrace = janet.janet_stacktrace;

pub const SIGNAL_OK = janet.JANET_SIGNAL_OK;
pub const SIGNAL_EVENT = janet.JANET_SIGNAL_EVENT;

pub const BINDING_DEF = janet.JANET_BINDING_DEF;

// TODO needed to rename these
pub const janet_type = janet.janet_type;
pub const fiber_continue = janet.janet_continue;

pub const pcall = janet.janet_pcall;

pub const resolve = janet.janet_resolve;
pub fn resolveBindingDef(env: *JanetTable, sym: JanetSymbol) !Janet {
    var ret: Janet = undefined;
    const f = janet.janet_resolve(env, sym, &ret);
    if (f != BINDING_DEF) {
        return error.JanetBindingDefNotFound;
    }
    return ret;
}
