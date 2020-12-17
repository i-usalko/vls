module vls

import lsp
import v.token
import v.util

// compute_offset returns a byte offset from the given position
pub fn compute_offset(source string, line int, col int) int {
	lines := source.split_into_lines()
	mut offset := 0
	for i, ln in lines {
		if i == line {
			if col > ln.len {
				return -1
			}
			if ln.len == 0 {
				offset++
				break
			}
			offset += col
			break
		} else {
			offset += ln.len+1
		}
	}
	unsafe {
		lines.free()
	}
	return offset
}

fn get_column(source string, init_pos int) int {
	mut p := init_pos
	if source.len > 0 {
		for ; p >= 0; p-- {
			if source[p] == `\r` || source[p] == `\n` {
				break
			}
		}
	}
	return p - 1
}

// position_to_lsp_pos converts the token.Position into lsp.Position
pub fn position_to_lsp_pos(source string, pos token.Position) lsp.Position {
	p := util.imax(0, util.imin(source.len - 1, pos.pos))
	column := util.imax(0, pos.pos - get_column(source, p)) - 1
	return lsp.Position{ 
		line: pos.line_nr, 
		character: util.imax(1, column) - 1
	}
}

// position_to_lsp_pos converts the token.Position into lsp.Range
fn position_to_lsp_range(source string, pos token.Position) lsp.Range {
	start_pos := position_to_lsp_pos(source, pos)
	return lsp.Range{ 
		start: start_pos, 
		end: { start_pos | character: start_pos.character + pos.len }
	}
}