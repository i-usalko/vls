// TODO: This code will be probably moved to features.v depending on the
// complexity of the code. What you're seeing here is not final so please
// bear in mind about it. 
// TODO: Add tests for it
module vls

import lsp
import os
import jsonrpc
import json
import v.ast
import v.table

struct CompletionItemConfig {
	pub_only bool = true
	mod      string
	file     ast.File
	offset   int
	table    &table.Table
}

// type CompletionSource = ast.Stmt | ast.Expr | table.Fn | table.TypeInfo

fn (ls Vls) completion_items_from_stmt(stmt ast.Stmt, cfg CompletionItemConfig) []lsp.CompletionItem {
	mut completion_items := []lsp.CompletionItem{}
	match stmt {
		ast.StructDecl {
			if cfg.pub_only && !stmt.is_pub {
				return completion_items
			}
			mut insert_text := stmt.name.all_after('${cfg.mod}.') + '{\n'
			mut i := stmt.fields.len - 1
			for field in stmt.fields {
				if field.has_default_expr {
					continue
				}
				// TODO: trigger autocompletion
				insert_text += '\t$field.name: \$$i\n'
				i--
			}
			insert_text += '}'
			completion_items << lsp.CompletionItem{
				label: stmt.name.all_after('${cfg.mod}.') + '{}'
				kind: .struct_
				insert_text: insert_text
				insert_text_format: .snippet
			}
		}
		ast.ConstDecl {
			if cfg.pub_only && !stmt.is_pub {
				return completion_items
			}
			completion_items << stmt.fields.map(lsp.CompletionItem{
				label: it.name.all_after('${cfg.mod}.')
				kind: .constant
				insert_text: it.name.all_after('${cfg.mod}.')
			})
		}
		ast.EnumDecl {
			if cfg.pub_only && !stmt.is_pub {
				return completion_items
			}
			for field in stmt.fields {
				label := stmt.name.all_after('${cfg.mod}.') + '.' + field.name
				completion_items << lsp.CompletionItem{
					label: label
					kind: .enum_member
					insert_text: label
				}
			}
		}
		ast.TypeDecl {
			match stmt {
				ast.AliasTypeDecl, ast.SumTypeDecl, ast.FnTypeDecl {
					label := stmt.name.all_after('${cfg.mod}.')
					completion_items << lsp.CompletionItem{
						label: label
						kind: .type_parameter
						insert_text: label
					}
				}
			}
		}
		ast.FnDecl {
			if (cfg.pub_only && !stmt.is_pub) || stmt.name == 'main.main' {
				return completion_items
			}
			completion_items << ls.completion_items_from_fn(table.Fn{
				name: stmt.name.all_after('${stmt.mod}.')
				is_generic: stmt.is_generic
				params: stmt.params
			}, stmt.is_method)
		}
		ast.InterfaceDecl {
			if cfg.pub_only && !stmt.is_pub {
				return completion_items
			}
			label := stmt.name.all_after('${cfg.mod}.')
			completion_items << lsp.CompletionItem{
				label: label
				kind: .interface_
				insert_text: label
			}
		}
		ast.ExprStmt {
			completion_items << ls.completion_items_from_expr(stmt.expr, cfg)
		}
		else {}
	}
	return completion_items
}

fn (ls Vls) completion_items_from_expr(expr ast.Expr, cfg CompletionItemConfig) []lsp.CompletionItem {
	mut completion_items := []lsp.CompletionItem{}
	mut expr_type := table.Type(0)
	if expr is ast.SelectorExpr {
		expr_type = expr.expr_type
		if expr_type == 0 && expr.expr is ast.Ident {
			ident := expr.expr as ast.Ident
			// ls.log_message('[completion_items_from_expr] creating data for $ident.name', .info)
			if ident.name !in cfg.file.imports.map(if it.alias.len > 0 { it.alias } else { it.mod }) {	
				return completion_items
			}
			for sym_name, stmt in ls.symbols {
				if !sym_name.starts_with(ident.name + '.') {
					continue
				}
				// NB: symbols of the said module does not show the full list
				// unless by pressing cmd/ctrl+space or by pressing escape key
				// + deleting the dot + typing again the dot
				completion_items << ls.completion_items_from_stmt(stmt, { cfg | mod: ident.name })
			}
		}
	}
	if expr_type != 0 {
		type_sym := cfg.table.get_type_symbol(expr_type)
		completion_items << ls.completion_items_from_type_info(type_sym.info)
		if type_sym.kind == .array || type_sym.kind == .map {
			base_symbol_name := if type_sym.kind == .array { 'array' } else { 'map' }
			if base_type_sym := cfg.table.find_type(base_symbol_name) {
				completion_items << ls.completion_items_from_type_info(base_type_sym.info)
			}
		}
		// list all methods
		for m in type_sym.methods {
			completion_items << ls.completion_items_from_fn(m, true)
		}
	}
	return completion_items
}

fn (ls Vls) completion_items_from_fn(fnn table.Fn, is_method bool) lsp.CompletionItem {
	mut i := 0
	mut insert_text := fnn.name
	if fnn.is_generic {
		insert_text += '<\${$i:T}>'
	}
	insert_text += '('
	for j, param in fnn.params {
		if is_method && j == 0 {
			continue
		}
		i++
		insert_text += '\${$i:$param.name}'
		if j < fnn.params.len - 1 {
			insert_text += ', '
		}
	}
	insert_text += ')'
	return lsp.CompletionItem{
		label: fnn.name
		kind: .method
		insert_text_format: .snippet
		insert_text: insert_text
	}
}

fn (ls Vls) completion_items_from_type_info(type_info table.TypeInfo) []lsp.CompletionItem {
	mut completion_items := []lsp.CompletionItem{}
	match type_info {
		table.Struct {
			for field in type_info.fields {
				completion_items << lsp.CompletionItem{
					label: field.name
					kind: .field
					insert_text: field.name
				}
			}
		}
		table.Enum {
			for val in type_info.vals {
				completion_items << lsp.CompletionItem{
					label: '.$val'
					kind: .field
					insert_text: '.$val'
				}
			}
		}
		else {}
	}
	return completion_items
}

// TODO: make params use lsp.CompletionParams in the future
fn (mut ls Vls) completion(id int, params string) {
	completion_params := json.decode(lsp.CompletionParams, params) or { panic(err) }
	file_uri := completion_params.text_document.uri
	dir := os.dir(file_uri)
	file := ls.files[file_uri.str()]
	src := ls.sources[file_uri.str()]

	mut pos := completion_params.position
	mut offset := compute_offset(src, pos.line, pos.character)
	mut ctx := completion_params.context
	mut show_global := true
	mut show_global_fn := false
	mut show_local := true
	mut completion_items := []lsp.CompletionItem{}
	mut filter_type := table.Type(0)
	
	// adjust context data if the trigger symbols are on the left
	if ctx.trigger_kind == .invoked && offset - 1 >= 0 && file.stmts.len > 0 && src.len > 3 {
		if src[offset - 1] in [`.`, `:`, `=`] {
			ctx = lsp.CompletionContext{
				trigger_kind: .trigger_character
				trigger_character: src[offset - 1].str()
			}
		} else if src[offset - 1] == ` ` && offset - 2 >= 0 && src[offset - 2] !in [src[offset - 1], `.`] {
			ctx = lsp.CompletionContext{
				trigger_kind: .trigger_character
				trigger_character: src[offset - 2].str()
			}

			offset -= 2
			pos = { pos | character: pos.character - 2 }
		}
	}

	table := ls.tables[dir]
	cfg := CompletionItemConfig{
		mod: file.mod.name
		file: file
		offset: offset
		table: table
	}

	// ls.log_message('position: { line: $pos.line, col: $pos.character } | offset: $offset | trigger_kind: $ctx', .info)
	if ctx.trigger_kind == .trigger_character {
		// TODO: will be replaced with the v.ast one
		if ctx.trigger_character == '.' {
			node := file.stmts.map(AstNode(it)).find_by_pos(offset - 2) or { AstNode{} }
			show_global = false
			show_local = false
			if node is ast.Stmt {
				completion_items <<
					ls.completion_items_from_stmt(node, cfg)
			}
		} else {
			ls.log_message(ctx.trigger_character, .info)
			node := file.stmts.map(AstNode(it)).find_by_pos(offset) or { AstNode{} }
			if node is ast.Stmt {
				// TODO: transfer it to completion_item_for_stmt
				match node {
					ast.AssignStmt {
						// TODO: support for multi assign
						if node.op != .decl_assign {
							show_global = false
							filter_type = node.left_types[node.left_types.len - 1]
						}
					}
					else {
						ls.log_message(typeof(node), .info)
					}
				}
			} else if node is ast.Expr {
				ls.log_message(typeof(node), .info)
				// TODO: transfer it to completion_item_for_expr
				match node {
					ast.StructInit {
						show_global = false
						show_local = false
						field_node := node.fields.map(AstNode(it)).find_by_pos(offset - 1) or { AstNode{} }
						if field_node is ast.StructInitField {
							// NB: enable local results only if the node is a field
							show_local = true
							field_type_sym := table.get_type_symbol(field_node.expected_type)
							completion_items << ls.completion_items_from_type_info(field_type_sym.info)
							filter_type = field_node.expected_type
						}
					}
					else {
						ls.log_message(typeof(node), .info)
					}
				}
			}
		}
	} else if ctx.trigger_kind == .invoked && (file.stmts.len == 0 || src.len <= 3) {
		// should never happen but just to make sure
		show_global = false
		show_local = false

		folder_name := os.base(os.dir(file_uri.str())).replace(' ', '_')
		module_name_suggestions := ['module main', 'module $folder_name']
		
		for sg in module_name_suggestions {
			completion_items << lsp.CompletionItem{
				label: sg
				insert_text: sg
				kind: .variable
			}
		}
	} else {
		show_global_fn = true
	}

	if show_local {
		if filter_type == 0 {
			// get the module names
			for imp in file.imports {
				if imp.mod in ls.invalid_imports[file_uri.str()] {
					continue
				}
				
				completion_items << lsp.CompletionItem{
					label: if imp.alias.len > 0 { imp.alias } else { imp.mod }
					kind: .module_
				}
			}
		}

		scope := file.scope.innermost(offset)
		// get variables inside the scope
		for _, obj in scope.objects {
			if obj is ast.Var {
				if filter_type != 0 && obj.typ != filter_type {
					continue
				}
				completion_items << lsp.CompletionItem{
					label: obj.name
					kind: .variable
					insert_text: obj.name
				}
			}
		}
	}
	
	if show_global {
		for fpath, ffile in ls.files {
			if !fpath.starts_with(dir) {
				continue
			}
			for stmt in ffile.stmts {
				if show_global_fn && stmt !is ast.FnDecl {
					continue
				}
				completion_items <<
					ls.completion_items_from_stmt(stmt, { cfg | mod: ffile.mod.name, file: ffile, pub_only: false })
			}
		}
	}

	if completion_items.len > 0 {
		ls.send(json.encode(jsonrpc.Response<[]lsp.CompletionItem>{
			id: id
			result: completion_items
		}))
	}
	unsafe { completion_items.free() }
}

// TODO: remove later if table is sufficient enough for grabbing information
// extract_symbols extracts the top-level statements and stores them into ls.symbols for quick access
fn (mut ls Vls) extract_symbols(parsed_files []ast.File, table &table.Table, pub_only bool) {
	for file in parsed_files {
		for stmt in file.stmts {
			if stmt is ast.FnDecl {
				if stmt.is_method {
					continue
				}
			}
			mut name := ''
			match stmt {
				ast.InterfaceDecl, ast.StructDecl, ast.EnumDecl, ast.FnDecl {
					if pub_only && !stmt.is_pub {
						continue
					}
					name = stmt.name
				}
				else {
					continue
				}
			}
			ls.symbols[name] = stmt
		}
	}
}
