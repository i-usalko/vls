module vls

import v.table
import v.ast
import v.pref
import json
import jsonrpc
import lsp

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
	// TODO: change map key to DocumentUri
	// files  map[DocumentUri]ast.File
	files      map[string]ast.File
	// sources  map[DocumentUri][]byte
	sources    map[string][]byte
	// NB: a separate table is required for each folder in
	// order to do functions such as typ_to_string or when
	// some of the features needed additional information
	// that is mostly stored into the table.
	//
	// A single table is not feasible since files are always
	// changing and there can be instances that a change might
	// break another module/project data.
	// tables  map[DocumentUri]&table.Table
	tables     map[string]&table.Table
	root_path  lsp.DocumentUri
pub mut:
	// TODO: replace with io.ReadWriter
	io         ReceiveSender
}

pub fn new(io ReceiveSender) Vls {
	mut tbl := table.new_table()
	tbl.is_fmt = false
	return Vls{
		io: io
		base_table: tbl
	}
}

pub fn (mut ls Vls) dispatch(payload string) {
	request := json.decode(jsonrpc.Request, payload) or {
		ls.send(new_error(jsonrpc.parse_error))
		return
	}
	if ls.status == .initialized {
		match request.method { // not only requests but also notifications
			'initialized' {} // does nothing currently
			'shutdown' {
				// NB: Some users reported that after closing their text editors,
				// the vls process isn't properly closed at all and the editor still
				// continuously sending useless requests during the shutdown phase
				// which dramatically increases the memory. Unless there is a fix
				// or other possible alternatives, the solution for now is to
				// immediately exit when the server receives a shutdown request.
				ls.exit()
				// ls.shutdown(request.id)
			}
			'exit' { /* ignore for the reasons stated in the above comment */ }
			'textDocument/didOpen' { ls.did_open(request.id, request.params) }
			'textDocument/didChange' { ls.did_change(request.id, request.params) }
			'textDocument/didClose' { ls.did_close(request.id, request.params) }
			'textDocument/formatting' { ls.formatting(request.id, request.params) }
			'textDocument/documentSymbol' { ls.document_symbol(request.id, request.params) }
			'workspace/symbol' { ls.workspace_symbol(request.id, request.params) }
			else {}
		}
	} else {
		match request.method {
			'exit' { ls.exit() }
			'initialize' { ls.initialize(request.id, request.params) }
			else {
				err_type := if ls.status == .shutdown { jsonrpc.invalid_request } else { jsonrpc.server_not_initialized }
				ls.send(new_error(err_type))
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
		ls.dispatch(payload)
	}
}

// new_scope_and_pref returns a new instance of scope and pref based on the given lookup paths
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

// insert_files inserts an array file asts onto the ls.files map
fn (mut ls Vls) insert_files(files []ast.File) {
	for file in files {
		file_uri := lsp.document_uri_from_path(file.path)
		if file_uri.str() in ls.files {
			ls.files.delete(file_uri)
		}
		ls.files[file_uri.str()] = file
		unsafe {
			file_uri.free()
		}
	}
}

// new_table returns a new table based on the existing data of base_table
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

pub enum ServerStatus {
	off
	initialized
	shutdown
}

[inline]
fn new_error(code int) string {
	err := jsonrpc.Response2<string>{
		error: jsonrpc.new_response_error(code)
	}
	return json.encode(err)
}
