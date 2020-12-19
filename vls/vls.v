module vls

import v.table
import v.ast
import v.pref
import json
import jsonrpc

pub const (
	// These are the list of features available in VLS
	// If the feature is experimental, the name should have a `experimental:` prefix
	features_list = [
		'diagnostics', 
		'formatting'
	]
)

interface ReceiveSender {
	send(data string)
	receive() ?string
}

struct Vls {
mut:
	// NB: a base table is required since this is where we
	// are gonna store the information for the builtin types
	// which are only parsed once.
	base_table &table.Table
	status     ServerStatus = .off
	files      map[string]ast.File
	sources    map[string]string
	// NB: a separate table is required for each folder in
	// order to do functions such as typ_to_string or when
	// some of the features needed additional information
	// that is mostly stored into the table.
	//
	// A single table is not feasible since files are always
	// changing and there can be instances that a change might
	// break another module/project data.
	tables     map[string]&table.Table
	root_path  string
	enabled_features   map[string]bool
pub mut:
	// TODO: replace with io.ReadWriter
	io         ReceiveSender
}

pub fn new(io ReceiveSender) Vls {
	mut enabled_features := map[string]bool{}
	mut tbl := table.new_table()
	tbl.is_fmt = false
	for f_name in features_list {
		is_experimental := f_name.starts_with('experimental:')
		features_name := f_name.all_after('experimental:')
		// stable feature (!is_experimental) = true
		// experimental = false
		enabled_features[features_name] = !is_experimental
	}
	return Vls{
		io: io
		base_table: tbl
		enabled_features: enabled_features
	}
}

pub fn (mut ls Vls) execute(payload string) {
	request := json.decode(jsonrpc.Request, payload) or {
		ls.send(new_error(jsonrpc.parse_error))
		return
	}
	if request.method != 'exit' && ls.status == .shutdown {
		ls.send(new_error(jsonrpc.invalid_request))
		return
	}
	if request.method != 'initialize' && ls.status != .initialized {
		ls.send(new_error(jsonrpc.server_not_initialized))
		return
	}
	match request.method {
		'initialize' {
			ls.initialize(request.id, request.params)
		}
		'initialized' {} // does nothing currently
		'shutdown' {
			ls.shutdown(request.params)
		}
		'exit' {
			ls.exit(request.params)
		}
		'textDocument/didOpen' {
			ls.did_open(request.id, request.params)
		}
		'textDocument/didChange' {
			ls.did_change(request.id, request.params)
		}
		'textDocument/formatting' {
			if ls.enabled_features['formatting'] {
				ls.formatting(request.id, request.params)
			}
		}
		else {
			if ls.status != .initialized {
				ls.send(new_error(jsonrpc.server_not_initialized))
			}
		}
	}
}

// status returns the current server status
pub fn (ls Vls) status() ServerStatus {
	return ls.status
}

// TODO: fn (ls Vls) send<T>(data T) {
fn (ls Vls) send(data string) {
	ls.io.send(data)
}

// start_loop starts an endless loop which waits for stdin and prints responses to the stdout
pub fn (mut ls Vls) start_loop() {
	for {
		payload := ls.io.receive() or { continue }
		ls.execute(payload)
	}
}

//
fn new_scope_and_pref(lookup_paths ...string) (&ast.Scope, &pref.Preferences) {
	mut lpaths := [vlib_path, vmodules_path]
	for i := lookup_paths.len - 1; i >= 0; i-- {
		lookup_path := lookup_paths[i]
		lpaths.prepend(lookup_path)
	}
	scope := &ast.Scope{
		parent: 0
	}
	prefs := &pref.Preferences{
		output_mode: .silent
		backend: .c
		os: ._auto
		lookup_path: lpaths
	}
	return scope, prefs
}

fn (mut ls Vls) insert_files(files []ast.File) {
	for file in files {
		if file.path in ls.files {
			ls.files.delete(file.path)
		}
		ls.files[file.path] = file
	}
}

// new_table returns a new table based on the existing data from base_table
fn (ls Vls) new_table() &table.Table {
	mut tbl := table.new_table()
	tbl.types = ls.base_table.types.clone()
	tbl.type_idxs = ls.base_table.type_idxs.clone()
	tbl.fns = ls.base_table.fns.clone()
	tbl.imports = ls.base_table.imports.clone()
	tbl.modules = ls.base_table.modules.clone()
	tbl.cflags = ls.base_table.cflags.clone()
	tbl.redefined_fns = ls.base_table.redefined_fns.clone()
	tbl.fn_gen_types = ls.base_table.fn_gen_types.clone()
	tbl.cmod_prefix = ls.base_table.cmod_prefix
	tbl.is_fmt = ls.base_table.is_fmt
	return tbl
}

// set_features enables or disables a language feature. emits an error if not found
pub fn (mut ls Vls) set_features(features []string, state bool) ? {
	for feature_name in features {
		if feature_name !in ls.enabled_features {
			return error('feature "$feature_name" not found')
		}

		ls.enabled_features[feature_name] = state
	}
}

pub enum ServerStatus {
	off
	initialized
	shutdown
}

// with error
struct JrpcResponse2 <T> {
	jsonrpc string = jsonrpc.version
	id      int
	error   jsonrpc.ResponseError
	result  T
}

[inline]
fn new_error(code int) string {
	err := JrpcResponse2<string>{
		error: jsonrpc.new_response_error(code)
	}
	return json.encode(err)
}
