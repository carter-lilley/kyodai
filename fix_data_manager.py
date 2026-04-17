import re

FILE_PATH = r"C:\Users\carter\Documents\GitHub\kyodai\managers\data_manager.gd"

HELPERS = """var _db_mutex: Mutex = Mutex.new()
var _db_mutex_owner: int = -1
var _db_mutex_count: int = 0

func _db_lock():
	var tid = OS.get_thread_id()
	if _db_mutex_owner == tid:
		_db_mutex_count += 1
	else:
		_db_mutex.lock()
		_db_mutex_owner = tid
		_db_mutex_count = 1

func _db_unlock():
	var tid = OS.get_thread_id()
	if _db_mutex_owner == tid:
		_db_mutex_count -= 1
		if _db_mutex_count == 0:
			_db_mutex_owner = -1
			_db_mutex.unlock()

func _db_query_array(query: String) -> Array:
	_db_lock()
	var success = _db.query(query)
	var result = _db.query_result.duplicate() if success else []
	_db_unlock()
	return result

func _db_query_bool(query: String) -> bool:
	_db_lock()
	var success = _db.query(query)
	_db_unlock()
	return success
"""

def get_indent(line):
    stripped = line.lstrip('\t')
    return line[:len(line) - len(stripped)]

def process():
    with open(FILE_PATH, "r", encoding="utf-8") as f:
        lines = f.readlines()

    out = []
    i = 0

    while i < len(lines):
        line = lines[i]
        indent = get_indent(line)

        # Insert helpers after _is_db_ready
        if "var _is_db_ready: bool = false" in line:
            out.append(line)
            out.append("\n")
            out.append(HELPERS)
            i += 1
            continue

        # Pattern: return _db.query(query),
        m = re.match(r'^(\s*)return _db\.query\((.+)\),(\s*)$', line)
        if m:
            out.append(f'{m.group(1)}return _db_query_bool({m.group(2)}),{m.group(3)}\n')
            i += 1
            continue

        # Pattern: return _db.query(query)
        m = re.match(r'^(\s*)return _db\.query\((.+)\)(\s*)$', line)
        if m:
            out.append(f'{m.group(1)}return _db_query_bool({m.group(2)})\n')
            i += 1
            continue

        # Rule 1: if not _db.query(...): <return> ... _db.query_result ...
        m = re.match(r'^(\t*)if\s+not\s+_db\.query\((.+)\)\s*:\s*$', line)
        if m:
            indent = m.group(1)
            query_expr = m.group(2)
            j = i + 1
            return_line = None
            while j < len(lines) and lines[j].strip() == '':
                j += 1
            if j < len(lines) and len(get_indent(lines[j])) > len(indent):
                return_line = lines[j]
                j += 1
            while j < len(lines) and lines[j].strip() == '':
                j += 1
            block_lines = []
            found_usage = False
            while j < len(lines):
                l = lines[j]
                if l.strip() == '':
                    block_lines.append(l)
                    j += 1
                    continue
                line_indent = get_indent(l)
                if not found_usage:
                    if len(line_indent) < len(indent) and not l.strip().startswith('#'):
                        break
                    block_lines.append(l)
                    if '_db.query_result' in l:
                        found_usage = True
                    j += 1
                else:
                    if len(line_indent) < len(indent) and not l.strip().startswith('#'):
                        break
                    if len(line_indent) == len(indent) and '_db.query_result' not in l and not l.strip().startswith('#'):
                        break
                    block_lines.append(l)
                    j += 1
            if found_usage:
                out.append(f'{indent}var query_result = _db_query_array({query_expr})\n')
                out.append(f'{indent}if query_result.is_empty():\n')
                if return_line:
                    out.append(indent + '\t' + return_line.lstrip())
                for bl in block_lines:
                    out.append(bl.replace('_db.query_result', 'query_result'))
                i = j
                continue

        # Rule 2a: if <cond> and _db.query(...) and _db.query_result.size() > 0:
        m = re.match(r'^(\t*)if\s+(.*?)\s+and\s+_db\.query\((.+)\)\s+and\s+_db\.query_result\.size\(\)\s*>\s*0:\s*$', line)
        if m:
            indent = m.group(1)
            cond = m.group(2)
            query_expr = m.group(3)
            out.append(f'{indent}var query_result = _db_query_array({query_expr})\n')
            out.append(f'{indent}if {cond} and query_result.size() > 0:\n')
            block_start = i + 1
            l = block_start
            while l < len(lines):
                if lines[l].strip() == '':
                    l += 1
                    continue
                if len(get_indent(lines[l])) <= len(indent):
                    break
                l += 1
            for idx in range(block_start, l):
                out.append(lines[idx].replace('_db.query_result', 'query_result'))
            i = l
            continue

        # Rule 2b: if _db.query(...) and _db.query_result.size() > 0:
        m = re.match(r'^(\t*)if\s+_db\.query\((.+)\)\s+and\s+_db\.query_result\.size\(\)\s*>\s*0:\s*$', line)
        if m:
            indent = m.group(1)
            query_expr = m.group(2)
            out.append(f'{indent}var query_result = _db_query_array({query_expr})\n')
            out.append(f'{indent}if query_result.size() > 0:\n')
            block_start = i + 1
            l = block_start
            while l < len(lines):
                if lines[l].strip() == '':
                    l += 1
                    continue
                if len(get_indent(lines[l])) <= len(indent):
                    break
                l += 1
            for idx in range(block_start, l):
                out.append(lines[idx].replace('_db.query_result', 'query_result'))
            i = l
            continue

        # Rule 3: var success = _db.query(...) \n if success: \n block with _db.query_result
        m = re.match(r'^(\t*)var\s+success\s*=\s*_db\.query\((.+)\)\s*$', line)
        if m:
            indent = m.group(1)
            query_expr = m.group(2)
            j = i + 1
            while j < len(lines) and lines[j].strip() == '':
                j += 1
            if j < len(lines) and re.match(rf'^{re.escape(indent)}if\s+success\s*:\s*$', lines[j]):
                block_start = j + 1
                l = block_start
                while l < len(lines):
                    if lines[l].strip() == '':
                        l += 1
                        continue
                    if len(get_indent(lines[l])) <= len(indent):
                        break
                    l += 1
                out.append(f'{indent}var query_result = _db_query_array({query_expr})\n')
                for idx in range(block_start, l):
                    dedented = lines[idx]
                    if dedented.startswith('\t'):
                        dedented = dedented[1:]
                    out.append(dedented.replace('_db.query_result', 'query_result'))
                i = l
                continue

        # Rule 4: var success = _db.query(...) \n if success and _db.query_result.size() > 0:
        m = re.match(r'^(\t*)var\s+success\s*=\s*_db\.query\((.+)\)\s*$', line)
        if m:
            indent = m.group(1)
            query_expr = m.group(2)
            j = i + 1
            while j < len(lines) and lines[j].strip() == '':
                j += 1
            if j < len(lines) and re.match(rf'^{re.escape(indent)}if\s+success\s+and\s+_db\.query_result\.size\(\)\s*>\s*0:\s*$', lines[j]):
                block_start = j + 1
                l = block_start
                while l < len(lines):
                    if lines[l].strip() == '':
                        l += 1
                        continue
                    if len(get_indent(lines[l])) <= len(indent):
                        break
                    l += 1
                out.append(f'{indent}var query_result = _db_query_array({query_expr})\n')
                out.append(f'{indent}if query_result.size() > 0:\n')
                for idx in range(block_start, l):
                    dedented = lines[idx]
                    if dedented.startswith('\t'):
                        dedented = dedented[1:]
                    out.append(dedented.replace('_db.query_result', 'query_result'))
                i = l
                continue

        # Rule 6a: if _db.query(...): \n block with _db.query_result
        m = re.match(r'^(\t*)if\s+_db\.query\((.+)\)\s*:\s*$', line)
        if m:
            indent = m.group(1)
            query_expr = m.group(2)
            block_start = i + 1
            l = block_start
            found_usage = False
            block_lines = []
            while l < len(lines):
                lline = lines[l]
                if lline.strip() == '':
                    block_lines.append(lline)
                    l += 1
                    continue
                line_indent = get_indent(lline)
                if len(line_indent) <= len(indent):
                    break
                block_lines.append(lline)
                if '_db.query_result' in lline:
                    found_usage = True
                l += 1
            if found_usage:
                out.append(f'{indent}var query_result = _db_query_array({query_expr})\n')
                for bl in block_lines:
                    dedented = bl
                    if dedented.startswith('\t'):
                        dedented = dedented[1:]
                    out.append(dedented.replace('_db.query_result', 'query_result'))
                i = l
                continue

        # Rule 5: _db.query(...) on its own line with subsequent _db.query_result usage
        m = re.match(r'^(\t*)_db\.query\((.+)\)\s*$', line)
        if m:
            indent = m.group(1)
            query_expr = m.group(2)
            j = i + 1
            block_lines = []
            found_usage = False
            while j < len(lines):
                l = lines[j]
                if l.strip() == '':
                    block_lines.append(l)
                    j += 1
                    continue
                line_indent = get_indent(l)
                if not found_usage:
                    if len(line_indent) < len(indent) and not l.strip().startswith('#'):
                        break
                    block_lines.append(l)
                    if '_db.query_result' in l:
                        found_usage = True
                    j += 1
                else:
                    if len(line_indent) < len(indent) and not l.strip().startswith('#'):
                        break
                    if len(line_indent) == len(indent) and '_db.query_result' not in l and not l.strip().startswith('#'):
                        break
                    block_lines.append(l)
                    j += 1
            if found_usage:
                out.append(f'{indent}var query_result = _db_query_array({query_expr})\n')
                for bl in block_lines:
                    out.append(bl.replace('_db.query_result', 'query_result'))
                i = j
                continue

        out.append(line)
        i += 1

    # Pass 2: Replace remaining _db.query( with _db_query_bool(, excluding protected regions
    def replace_remaining(lines_list):
        result = []
        in_insert = False
        in_remove = False
        in_remove_lambda = False
        remove_lambda_indent = ""
        for line in lines_list:
            if line.strip().startswith("func _insert_games_transaction"):
                in_insert = True
            elif line.strip().startswith("func ") and in_insert:
                in_insert = False

            if line.strip().startswith("func remove_platform_games"):
                in_remove = True
            elif line.strip().startswith("func ") and in_remove:
                in_remove = False
                in_remove_lambda = False

            if in_remove and line.strip() == "func():":
                in_remove_lambda = True
                remove_lambda_indent = get_indent(line)
            elif in_remove_lambda and line.strip().startswith("func ") and len(get_indent(line)) <= len(remove_lambda_indent):
                in_remove_lambda = False

            if '_db.query(' in line and not line.strip().startswith('#'):
                if not (in_insert or in_remove_lambda):
                    line = line.replace('_db.query(', '_db_query_bool(')
            result.append(line)
        return result

    out = replace_remaining(out)

    # Pass 3: Wrap _insert_games_transaction with lock/unlock
    final_out = []
    i = 0
    while i < len(out):
        line = out[i]
        final_out.append(line)
        if line.strip().startswith("func _insert_games_transaction"):
            j = i + 1
            while j < len(out):
                if "if not _is_db_ready or games.is_empty():" in out[j]:
                    final_out.append(out[j])
                    j += 1
                    final_out.append(out[j])  # return false
                    j += 1
                    final_out.append(get_indent(out[j]) + "_db_lock()\n")
                    break
                else:
                    final_out.append(out[j])
                    j += 1
            lock_inserted = True
            while j < len(out):
                l = out[j]
                if l.strip().startswith("func ") and get_indent(l) == "":
                    break
                if lock_inserted and l.strip().startswith("return "):
                    final_out.append(get_indent(l) + "_db_unlock()\n")
                final_out.append(l)
                j += 1
            i = j
            continue
        i += 1

    # Pass 4: Wrap remove_platform_games lambda with lock/unlock
    final_out2 = []
    i = 0
    while i < len(final_out):
        line = final_out[i]
        final_out2.append(line)
        if 'print("[Sync] DB task executing for %s" % platform_slug)' in line:
            indent = get_indent(line)
            final_out2.append(indent + "_db_lock()\n")
            i += 1
            continue
        if line.strip().startswith("return {"):
            if i + 1 < len(final_out) and '"success": success' in final_out[i + 1]:
                indent = get_indent(line)
                final_out2.pop()
                final_out2.append(indent + "_db_unlock()\n")
                final_out2.append(line)
                i += 1
                continue
        i += 1

    with open(FILE_PATH, "w", encoding="utf-8") as f:
        f.writelines(final_out2)

if __name__ == "__main__":
    process()
