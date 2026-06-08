Module_Import :: struct {
    module: string;
    root: string;
    is_using: bool;
}

Program_File :: struct {
    path: string;
    imports: [..]Module_Import;
    loads: [..]*Directive_Load;
    nodes: [..]*Node;
    global_block: Block;
    declarations: Table(string, *Declaration);
    comments: [..]Comment_Token;
    // resolved_identifiers: Table(*Identifier, []*Declaration);
    linked_files: []Linked_File; // @TODO: this is probably stupid name for this!

    ast_pool: Pool;
    analysis_pool: Pool;

    mutex: Mutex;  // guards declarations + nodes during concurrent worker access
}

Linked_File :: struct {
    from_import: bool;
    file: *Program_File;
}

resizable_array_identifier := Identifier.{
    name = "Resizable_Array",
};

empty_identifier := Identifier.{
    name = "",
};

s64_node := Identifier.{
    name = "s64",
};

void_star_node := Identifier.{
    name = "*void",
};

unknown_identifier_node := Identifier.{
    name = "---",
};

array_count_declaration := Declaration.{
    name = "count",
    type_inst = xx *s64_node
};

deinit_file :: (using file: Program_File) {
    deinit(*declarations);
    destroy(*file.mutex);
    array_free(nodes);
    array_free(loads);
    array_free(imports);
    array_free(comments);
    release(*file.ast_pool);
    release(*file.analysis_pool);
}

deinit_server_files :: () {
    for file: server.files {
        if !file continue;
        deinit_file(file.*);
        if file.path.count > 0 free(file.path);
        free(file);
    }

    deinit(*server.files);
    array_free(server.files_to_be_analyzed);
}

deinit_inserted_fields :: () {
    for members: server.inserted_fields {
        array_free(members);
    }

    deinit(*server.inserted_fields);

    for members, name: server.inserted_fields_by_name {
        array_free(members);
        if name.count > 0 free(name);
    }

    deinit(*server.inserted_fields_by_name);

    for members: server.inserted_fields_by_type_id {
        array_free(members);
    }

    deinit(*server.inserted_fields_by_type_id);

    for _, key: server.decl_type_ids {
        if key.count > 0 free(key);
    }

    deinit(*server.decl_type_ids);
}

reset_file :: (using file: Program_File) {
    table_reset(*declarations);
    array_reset(*nodes);
    array_reset(*loads);
    array_reset(*imports);
    array_reset(*comments);
    release(*file.ast_pool);
}

get_file :: (path: string) -> *Program_File {
    lock(*server.files_mutex);
    ok, file := table_find(*server.files, path);
    unlock(*server.files_mutex);
    if !ok return null;
    return file;
}

path_is_allowed :: (path: string) -> bool {
    if path.count == 0 return true; // empty path handled by caller
    // Allow paths within project root or Jai runtime directory
    if begins_with(path, server.project_root) return true;
    if server.args.jai_path.count > 0 && begins_with(path, server.args.jai_path) return true;
    log_error("Path traversal blocked: '%' (root='%', jai='%')", path, server.project_root, server.args.jai_path);
    return false;
}

search_for_file :: (name: string) -> *Program_File {
    final_file: *Program_File;

    for file, file_name: server.files {
        if contains(file_name, name) {
            final_file = file;
        }
    }

    return final_file;
}

normalize_path :: (path: string) -> string {
    normalized_path := decode_url(path);

    #if OS == .WINDOWS {
        normalized_path = replace(normalized_path, "file:///", "");
        path_overwrite_separators(normalized_path, #char "/");
    } else {
        normalized_path = replace(normalized_path, "file://", "");
    }

    parsed := parse_path(normalized_path, reduce=true);
    return path_to_string(parsed);
}

normalize_and_copy_path :: (path: string) -> string {
    if(path.count == 0) {
        return "";
    }

    saved_allocator := context.allocator;
    context.allocator = temp;
    str := normalize_path(path);
    context.allocator = saved_allocator;
    return copy_string(str);
}

path_to_lsp_path :: (path: string) -> string {
    #if OS == .WINDOWS {
        return join("file:///", path);
    } else {
        return join("file://", path);
    }
}

pool_alloc :: (pool: *Pool) -> Allocator {
    return .{pool_allocator_proc, pool};
}

parse_file :: (input_path: string, force := false, shallow := false, follow_all := true) {
    // Reset back to default allocator, we dont want to use pool from "parent" file...
    context.allocator = context.default_allocator;

    // Thread-safe shallow flag: each caller passes its own value.
    // No global state mutation — node_visit reads server.shallow_parse
    // which is set per parse_file call.
    saved_shallow := server.shallow_parse;
    server.shallow_parse = shallow;
    defer server.shallow_parse = saved_shallow;

    // follow_all: root file gets all imports resolved; imported files
    // only follow 'using X :: #import "X"' declarations to prevent recursive
    // transitive loading (e.g. Basic → #import "POSIX" → 100+ modules).
    saved_follow_all := server.follow_all_imports;
    server.follow_all_imports = follow_all;
    defer server.follow_all_imports = saved_follow_all;

    saved_allocator_for_path := context.allocator;
    context.allocator = temp;
    path := normalize_path(input_path);
    context.allocator = saved_allocator_for_path;

    // Thread-safe find-or-create: protect server.files lookup + add with mutex
    lock(*server.files_mutex);
    ok, file := table_find(*server.files, path);
    if !force && ok {
        unlock(*server.files_mutex);
        // log("Skipping % because it already exists", path);
        return;
    }
    if ok {
        reset_file(file); // clear old data
        unlock(*server.files_mutex);
    } else {
        file = New(Program_File);
        file.path = copy_string(path);
        set_allocators(*file.ast_pool, context.default_allocator);
        set_allocators(*file.analysis_pool, context.default_allocator);
        init(*file.mutex);
        table_add(*server.files, file.path, file);
        unlock(*server.files_mutex);
    }

    // log("Parse file: %", path);

    content := cast(string) get_memory_file(path);
    content_from_file: bool;

    if content.count == 0 {
        // Validate path is within allowed roots before reading from disk
        if !path_is_allowed(path) {
            log_error("Refusing to read file outside project/Jai roots: %", path);
            return;
        }

        exists: bool;

        content, exists = read_entire_file(path, log_errors=false);
        if !exists {
            // log_error("File % does not exists!", path);
            return;
        }

        content_from_file = true;
    }

    path_without_filename := trim_right(path_strip_filename(file.path), "/");

    {
        _pool := pool_alloc(*file.ast_pool);

        push_allocator(_pool);

        parser: Parser(Node_Visit_Data);
        parser.user_data.allocator = _pool;
        parser.user_data.file = file;
        parser.user_data.path_without_filename = normalize_path(path_without_filename);
        parser.node_visit = node_visit;
        parser.lexer = *create_lexer(content, file.path);

        while !end(parser.lexer) {
            parse(*parser, null);
        }

        file.global_block.members = parser.user_data.global_members;
        file.comments = parser.lexer.comments;
    }

    if content_from_file free(content);
    // log("Parsed: % (nodes: %, declarations: %, pointer: %)", path, file.nodes.count, file.declarations.count, file);

    lock(*server.files_mutex);
    array_add_if_unique(*server.files_to_be_analyzed, file);

    // We must revalidate all files that are using this file in some way.
    // get_files_that_use DISABLED — temp allocator crashes in is_avaiable_from_impl
    // during recursive import traversal for large projects.
    // Scheduler loop handles incremental re-analysis per-file anyway.

    // Seed linked_files with Preload + Runtime_Support immediately so
    // completions have access to their declarations even before background
    // analysis runs (which overwrites linked_files with the full set).
    if file.linked_files.count == 0 {
        linked: [..]Linked_File;
        linked.allocator = pool_alloc(*file.analysis_pool);
        for f: server.files {
            if f == file continue;
            preload_or_runtime: bool;
            if contains(f.path, "Preload.jai")        preload_or_runtime = true;
            if contains(f.path, "Runtime_Support.jai") preload_or_runtime = true;
            if preload_or_runtime {
                array_add(*linked, .{ file=f, from_import=true });
            }
        }
        file.linked_files = linked;
    }
    unlock(*server.files_mutex);
}

// Full analysis: processes all files in files_to_be_analyzed at once.
// Used from initialize/didSave/didChange where the batch is small.
analyze_files :: () {
    for file: server.files_to_be_analyzed {
        release(*file.analysis_pool);
    }

    preload_file: *Program_File;
    runtime_support_file: *Program_File;

    for file: server.files {
        if !runtime_support_file && contains(file.path, "Runtime_Support.jai") {
            runtime_support_file = file;
        }

        if !preload_file && contains(file.path, "Preload.jai") {
            preload_file = file;
        }
    }

    for file: server.files_to_be_analyzed {
        linked_files := get_file_links(file,, pool_alloc(*file.analysis_pool));

        if file != preload_file && preload_file {
            array_add(*linked_files, .{ file=preload_file, from_import=true });
        }

        if file != runtime_support_file && runtime_support_file {
            array_add(*linked_files, .{ file=runtime_support_file, from_import=true });
        }

        file.linked_files = linked_files;
    }

    // for file: server.files_to_be_analyzed {
    //     resolve_identifiers(file, global_only=true,, pool_alloc(*file.analysis_pool));
    // }

    array_reset(*server.files_to_be_analyzed);
}

// Incremental analysis: process ONE file per call from the scheduler loop.
// Returns false when all files in files_to_be_analyzed are done (and sends
// "Indexing complete" progress message).
// This prevents blocking the main thread for seconds during get_file_links
// when the import tree has hundreds of files.
process_analysis_step :: () -> bool {
    if !server.analysis_pending {
        // First call — discover the batch
        for f: server.files_to_be_analyzed {
            release(*f.analysis_pool);
        }

        server.preload_file = null;
        server.runtime_support_file = null;
        for f: server.files {
            if !server.runtime_support_file && contains(f.path, "Runtime_Support.jai") {
                server.runtime_support_file = f;
            }
            if !server.preload_file && contains(f.path, "Preload.jai") {
                server.preload_file = f;
            }
        }

        server.analysis_index = 0;
        server.analysis_pending = true;
    }

    if server.analysis_index >= server.files_to_be_analyzed.count {
        // All done
        array_reset(*server.files_to_be_analyzed);
        server.analysis_pending = false;
        server.analysis_index = -1;
        server.preload_file = null;
        server.runtime_support_file = null;
        send_progress_end(tprint("jails-parse-%", server.progress_cycle), "Indexing complete");
        log("Background analysis complete");
        return false;
    }

    file := server.files_to_be_analyzed[server.analysis_index];
    server.analysis_index += 1;

    linked_files := get_file_links(file,, pool_alloc(*file.analysis_pool));

    if file != server.preload_file && server.preload_file {
        array_add(*linked_files, .{ file=server.preload_file, from_import=true });
    }

    if file != server.runtime_support_file && server.runtime_support_file {
        array_add(*linked_files, .{ file=server.runtime_support_file, from_import=true });
    }

    file.linked_files = linked_files;

    // Check if this was the last one
    if server.analysis_index >= server.files_to_be_analyzed.count {
        array_reset(*server.files_to_be_analyzed);
        server.analysis_pending = false;
        server.analysis_index = -1;
        server.preload_file = null;
        server.runtime_support_file = null;
        send_progress_end(tprint("jails-parse-%", server.progress_cycle), "Indexing complete");
        log("Background analysis complete");
        return false;
    }

    return true; // more files remain
}

Node_Visit_Data :: struct {
    file: *Program_File;
    global_members: [..]*Node;
    allocator: Allocator;
    path_without_filename: string;
}

node_visit :: (node: *Node, data: Node_Visit_Data) {
    if !node return;

    push_allocator(data.allocator);

    file := data.file;

    lock(*file.mutex);
    // defer unlock(*file.mutex);  // can't use defer — push_allocator above changes context

    if node.kind == .COMPOUND_DECLARATION {
        compound_declaration := cast(*Compound_Declaration) node;
        for member: compound_declaration.members {
            if member.kind != .COMPOUND_DECLARATION_ITEM continue;
            item := cast(*Compound_Declaration_Item) member;
            if item.item_kind != .DECLARATION || item.expression.kind != .IDENTIFIER continue;
            decl_ident := cast(*Identifier) item.expression;

            // @TODO: is this ok? Do we really wan't to create "virtual" decl here?
            decl := New(Declaration);
            decl.parent = decl_ident.parent;
            decl.location = decl_ident.location;
            decl.name = decl_ident.name;

            table_add(*file.declarations, decl.name, decl);
        }
    }

    if node.kind == .DECLARATION {
        decl := cast(*Declaration) node;
        table_add(*file.declarations, decl.name, decl);
    }

    array_add(*file.nodes, node);
    unlock(*file.mutex);

    if node.kind == .DIRECTIVE_IMPORT {
        _import := cast(*Directive_Import) node;

        path := get_module_import_path(_import, data.path_without_filename);
        if path.count > 0 path = normalize_path(path);

        parent := _import.parent;
        wrapped_in_decl := parent && parent.kind == .DECLARATION;
        wrapped_in_bare_using := parent && parent.kind == .USING;

        module_import: Module_Import;
        module_import.root = path;
        module_import.module = _import.module;
        module_import.is_using = wrapped_in_bare_using;

        if !wrapped_in_decl {
            array_add(*data.file.imports, module_import);
        }

        // follow_all=true (root file): follow EVERY #import (bare + using).
        // follow_all=false (imported file): only follow wrapped_in_decl —
        // prevents recursive transitive loading (e.g. Basic → #import "POSIX").
        root_or_wrapped := server.follow_all_imports || wrapped_in_decl || wrapped_in_bare_using;
        if root_or_wrapped {
            if server.shallow_parse {
                // Defer import parsing: collect path for background resolution
                // Copy using default allocator — current context is pool, freed on re-parse
                if path.count > 0 {
                    lock(*server.deferred_mutex);
                    saved := context.allocator;
                    context.allocator = context.default_allocator;
                    array_add_if_unique(*server.deferred_imports, copy_string(path));
                    context.allocator = saved;
                    unlock(*server.deferred_mutex);
                }
            } else {
                if path.count > 0 parse_file(path, false, false, false); // imported → restrict transitive
            }
        }
    }

    if node.kind == .USING {
        _using := cast(*Using) node;
        if _using.expression && _using.expression.kind == .DECLARATION {
            decl := cast(*Declaration) _using.expression;
            if decl.expression && decl.expression.kind == .DIRECTIVE_IMPORT {
                _import := cast(*Directive_Import) decl.expression;
                path := get_module_import_path(_import, data.path_without_filename);
                if path.count > 0 path = normalize_path(path);

                module_import: Module_Import;
                module_import.root = path;
                module_import.module = _import.module;
                module_import.is_using = true;

                array_add(*data.file.imports, module_import);
            }
        }
    }

    if node.kind == .DIRECTIVE_LOAD {
        _load := cast(*Directive_Load) node;

        load_relative_path := join(data.path_without_filename, _load.file, separator="/");
        array_add(*data.file.loads, _load);
        if server.shallow_parse {
            lock(*server.deferred_mutex);
            saved := context.allocator;
            context.allocator = context.default_allocator;
            array_add_if_unique(*server.deferred_imports, copy_string(load_relative_path));
            context.allocator = saved;
            unlock(*server.deferred_mutex);
        } else {
            if load_relative_path.count > 0 parse_file(load_relative_path, false, false, false); // imported → restrict transitive
        }
    }

    if !node.parent {
        array_add(*data.global_members, node);
        node.parent = *file.global_block;
    }
}

get_module_import_path :: (_import: *Directive_Import, current_path: string) -> string {

    get_module_entry :: (module: string) -> string {
        uri := join(module, "/module.jai");
        if file_exists(uri) return uri;

        uri = join(module, ".jai");
        if file_exists(uri) return uri;

        return "";
    }

    get_module :: (module_name: string) -> string {
        for local_modules_folder: server.local_modules {
            absolute_path: string;
            if is_absolute_path(local_modules_folder) {
                absolute_path = local_modules_folder;
            } else {
                absolute_path = join(server.project_root, local_modules_folder, separator="/");
            }

            absolute_path = normalize_path(absolute_path);

            entry := get_module_entry(join(absolute_path, module_name, separator="/"));
            if entry.count > 0 return entry;
        }

        jai_modules := join(server.args.jai_path, "/modules");

        entry := get_module_entry(join(jai_modules, module_name, separator="/"));
        if entry.count > 0 return entry;

        return "";
    }

    path: string;

    if _import.import_kind == {
        case .MODULE;
            path = get_module(_import.module);
            if path.count == 0 return "";
        case .FILE;
            path = sprint("%/%", current_path, _import.module);
        case .DIR;
            relative_path := sprint("%/%", current_path, _import.module);
            path = get_module_entry(relative_path);
            if path.count == 0 return "";
        case .STRING;
            return "";
            // @TODO: Do we wanna parse the string here?
    }

    return path;
}

// resolve_identifiers :: (file: *Program_File) {
//     for node: file.nodes {
//         if node.kind != .IDENTIFIER {
//             continue;
//         }

//         ident := cast(*Identifier) node;

//         // log("Resolving '%' ident at %:%:%", ident.name, ident.location.file, ident.location.l0, ident.location.c0);

//         // log("Ident: %", ident.name);
//         block := get_node_nearest_block(ident);
//         decls := get_declarations(file, block, *ident.location, ident.name);
//         if decls.count == 0 {
//             // array_add(*file.unresolved_identifiers, ident);
//             continue;
//         }

//         table_add(*file.resolved_identifiers, ident, decls);
//     }
// }

get_node_by_location :: (file: *Program_File, location: Node.Location, filter: Node.Kind = .UNINITIALIZATED) -> *Node {
    nodes := file.nodes;
    if nodes.count == 0 return null;

    // Binary search: find first node at or after target line
    // Jai .. is inclusive, so valid indices are [0, nodes.count-1]
    left := 0;
    right := nodes.count - 1;
    while left < right {
        mid := (left + right) / 2;
        if nodes[mid].location.l0 < location.l0 {
            left = mid + 1;
        } else {
            right = mid;
        }
    }

    nearest_node: *Node;

    // Scan backwards from binary search landing point — check all nodes.
    // Parent nodes can start far before target line, so no early break.
    i := left;
    while i >= 0 {
        node := nodes[i];
        if filter == .UNINITIALIZATED || node.kind == filter {
            if contains(node.location, location) {
                if !nearest_node || contains(nearest_node.location, node.location) {
                    nearest_node = node;
                }
            }
        }
        i -= 1;
    }

    // Scan forwards — safe to break when node starts after target line
    i = left + 1;
    while i < nodes.count {
        node := nodes[i];
        if node.location.l0 > location.l0 break; // starts after target — stop
        if filter == .UNINITIALIZATED || node.kind == filter {
            if contains(node.location, location) {
                if !nearest_node || contains(nearest_node.location, node.location) {
                    nearest_node = node;
                }
            }
        }
        i += 1;
    }

    return nearest_node;
}

get_file_links :: (file: *Program_File) -> [..]Linked_File {
    linked_files: [..]Linked_File;

    files_that_load_this_file := get_files_that_load(file);
    defer array_free(files_that_load_this_file);

    for server.files {
        // This ensure we take into account only files that are being loaded or imported...
        from_import: bool;

        if file.path != it.path {
            is_avaiable_from_one_of_the_parents: bool;

            for file_that_load_this_file: files_that_load_this_file {

                if file_that_load_this_file.path == it.path {
                    is_avaiable_from_one_of_the_parents = true;
                    break;
                }

                avaiable, from_import= := is_avaiable_from(file_that_load_this_file, it.path);
                if !avaiable continue;

                is_avaiable_from_one_of_the_parents = true;
                break;
            }

            if !is_avaiable_from_one_of_the_parents {
                avaiable, from_import= := is_avaiable_from(file, it.path);
                if !avaiable continue;
            }
        }

        array_add(*linked_files, .{ file=it, from_import=from_import });
    }

    return linked_files;
}

add_all_fields_of :: (decls: *[..]*Declaration, node: *Node, filter_name: string = "") {
    block := get_block_of(node);
    if !block {
        return;
    }

    for member: block.members {
        if !member continue;

        if member.kind == {
            case .IDENTIFIER;
                ident := cast(*Identifier) member;

                decl := New(Declaration); // @MEMORY: We should free this or it is temp?
                decl.name = ident.name;
                decl.expression = *empty_identifier;
                decl.location = ident.location;
                decl.const = true;

                if !filter_name || filter_name == decl.name array_add(decls, decl);

            case .DECLARATION;
                decl := cast(*Declaration) member;
                if !filter_name || filter_name == decl.name array_add(decls, decl);

            case .UNION;
                add_all_fields_of(decls, member);

            case .COMPOUND_DECLARATION;
                compound_declaration_to_declarations(decls, cast(*Compound_Declaration) member, filter_name);

            case .DIRECTIVE_AS; #through;
            case .USING; // @TODO: handle `using` modifiers like `except`, `only` and `map`.
                used_expression := get_used_expression(member);
                if !used_expression || used_expression.kind != .DECLARATION && used_expression.kind != .IDENTIFIER {
                    continue;
                }

                used_type := get_node_type(used_expression);
                if !used_type {
                    continue;
                }

                if used_expression.kind == .DECLARATION {
                    decl := cast(*Declaration) used_expression;
                    if !filter_name || filter_name == decl.name array_add(decls, decl); // Add using expression
                }

                add_all_fields_of(decls, used_type, filter_name); // Add all fields includes with using
        }
    }
}

// @TODO: Refactor this! (stupid global variable)
skip_using: *Using;

add_decls_from_using :: (decls: *[..]*Declaration, _using: *Using, name: string) {
    if skip_using == _using || !_using.expression || _using.expression.kind != .IDENTIFIER return;

    ident := cast(*Identifier) _using.expression;

    copied_using := skip_using;
    skip_using = _using;

    used_type := get_node_type(_using.expression);
    if !used_type return;

    add_all_fields_of(decls, used_type, name);

    skip_using = copied_using;
}

get_declarations_from_for :: (decls: *[..]*Declaration, node: *Node, from_loc: *Node.Location, name := "") {
    _for := cast(*For) node;

    saved_skip_node := skip_node;
    defer skip_node = saved_skip_node;
    skip_node = _for;
    iterator_type := get_node_type(_for.iterator, false);
    if !iterator_type {
        return;
    }

    element_type: *Node;

    if iterator_type.kind == {
        case .ARRAY_TYPE;
            array_type := cast(*Array_Type) iterator_type;
            if !array_type.element_type {
                return;
            }

            element_type = array_type.element_type;

        case .LITERAL;
            literal := cast(*Literal) iterator_type;
            if literal.value_type != .ARRAY {
                return;
            }

            element_type = literal.array_literal_info.element_type;
    }

    if !element_type {
        element_type = *unknown_identifier_node;
    }

    it_declaration := New(Declaration);
    it_declaration.name = "it";
    it_declaration.location = _for.iterator.location;

    if _for.value && _for.value.kind == .IDENTIFIER {
        value_identifier := cast(*Identifier) _for.value;
        it_declaration.name = value_identifier.name;
        it_declaration.location = value_identifier.location;
    }

    it_index_decl := New(Declaration);
    it_index_decl.name = "it_index";
    it_index_decl.location = _for.iterator.location;
    it_index_decl.type_inst = *s64_node;

    if _for.index && _for.index.kind == .IDENTIFIER {
        index_identifier := cast(*Identifier) _for.index;
        it_index_decl.name = index_identifier.name;
        it_index_decl.location = index_identifier.location;
    }

    if _for.by_pointer {
        pointer_wrapper := New(Unary_Operation);
        pointer_wrapper.operation = .POINTER;
        pointer_wrapper.expression = element_type;
        it_declaration.type_inst = pointer_wrapper;
    } else {
        it_declaration.type_inst = element_type;
    }

    if name.count == 0 || it_declaration.name == name array_add(decls, it_declaration);
    if name.count == 0 || it_index_decl.name == name array_add(decls, it_index_decl);
}

skip_node: *Node;

MAX_RECURSION_DEPTH :: 512; // guard against stack overflow in deeply nested ASTs

get_declarations_from_parent :: (decls: *[..]*Declaration, node: *Node, from_loc: *Node.Location, name := "", only_consts := false, depth: int = 0) {
    if !node return;
    if depth >= MAX_RECURSION_DEPTH {
        log_error("get_declarations_from_parent: max recursion depth (%%) reached", MAX_RECURSION_DEPTH);
        return;
    }

    if skip_node != null && node == skip_node || only_consts && node.kind != .BLOCK {
        get_declarations_from_parent(decls, node.parent, from_loc, name, only_consts, depth + 1);
        return;
    }

    if node.kind == {
        case .CASE;
            _case := cast(*Case) node;

            if !from_loc return;

            for _case.members {
                // We only accept `nodes` if they were declared before our cursor location.
                if from_loc.l0 < it.location.l0 continue;

                if it.kind == {
                    case .USING;
                        add_decls_from_using(decls, cast(*Using) it, name);

                    case .DECLARATION;
                        decl := cast(*Declaration) it;
                        if !name || name == decl.name array_add(decls, decl);
                }

            }


        case .PROCEDURE;
            proc := cast(*Procedure) node;

            for arg: proc.arguments {
                if arg.kind != .DECLARATION continue;
                decl := cast(*Declaration) arg;

                if name.count == 0 || decl.name == name array_add(decls, decl);
            }

            only_consts = true;

        case .STRUCT;
            _struct := cast(*Struct) node;

            for arg: _struct.polymorphic_arguments {
                if arg.kind != .DECLARATION continue;
                decl := cast(*Declaration) arg;

                if name.count == 0 || decl.name == name array_add(decls, decl);
            }

            only_consts = true;

        case .UNION;
            _union := cast(*Union) node;

            for arg: _union.polymorphic_arguments {
                if arg.kind != .DECLARATION continue;
                decl := cast(*Declaration) arg;

                if name.count == 0 || decl.name == name array_add(decls, decl);
            }

            only_consts = true;

        case .BLOCK;
            block := cast(*Block) node;

            // global file block we dont want that!
            if !block.parent {
                return;
            }

            if !from_loc return;

            for block.members {

                // We only accept `nodes` if they were declared before our cursor/node location.
                if from_loc.l0 < it.location.l0 continue;

                if it.kind == {
                    case .USING; // @TODO: solve crash when having two using
                        add_decls_from_using(decls, cast(*Using) it, name);

                    case .COMPOUND_DECLARATION;
                        comp_decl := cast(*Compound_Declaration) it;
                        if only_consts && !comp_decl.const {
                            continue;
                        }

                        compound_declaration_to_declarations(decls, comp_decl, name);

                    case .DECLARATION;
                        decl := cast(*Declaration) it;

                        add_decl := true;

                        if only_consts && !decl.const {
                            add_decl = false;
                        }

                        if name && name != decl.name {
                            add_decl = false;
                        }

                        if add_decl array_add(decls, decl);
                }

            }

        case .FOR; get_declarations_from_for(decls, node, from_loc, name);
    }

    get_declarations_from_parent(decls, node.parent, from_loc, name, only_consts, depth + 1);
}

get_declarations :: (file: *Program_File, from_node: *Node = null, from_loc: *Node.Location = null, name := "", only_loaded := false) -> []*Declaration {
    decls: [..]*Declaration;

    // File's own declarations — available immediately after didOpen.
    // linked_files is populated later by analyze_files() after background
    // import resolution completes.
    if file {
        if name.count > 0 {
            for decl: table_find_multiple(*file.declarations, name) {
                if is_global(decl, file, file, false) array_add(*decls, decl);
            }
        } else {
            for decl: file.declarations {
                if is_global(decl, file, file, false) array_add(*decls, decl);
            }
        }
    }

    // Globals in all linked files (loaded or imported).
    // linked_files is populated by analyze_files() after background import
    // resolution completes. During indexing (linked_files empty), completions
    // return only the file's own declarations — fast, no timeout.
    if file {
        for linked_file: file.linked_files {
            if only_loaded && linked_file.from_import {
                continue;
            }

            // -- Global using --
            // We are accepting usings only from loaded files.
            // if !linked_file.from_import {

            //     // This is stupid!!
            //     for linked_file.file.nodes {
            //         if !is_global(it, file, linked_file.file, linked_file.from_import) {
            //             continue;
            //         }

            //         if it.kind != .USING {
            //             continue;
            //         }

            //         _using := cast(*Using, it);

            //         if skip_using == _using {
            //             continue;
            //         }

            //         if !_using.expression {
            //             continue;
            //         }

            //         copied_using := skip_using;
            //         skip_using = _using;

            //         used_type := get_node_type(_using.expression);
            //         if !used_type continue;

            //         add_all_fields_of(*decls, used_type, name);

            //         skip_using = copied_using;
            //     }
            // }

            // Protect against concurrent modification by worker threads
            // (workers call parse_file -> node_visit -> table_add(*file.declarations))
            lock(*linked_file.file.mutex);
            // We are searching for specific decl
            if name.count > 0 {
                for decl: table_find_multiple(*linked_file.file.declarations, name) {
                    if is_global(decl, file, linked_file.file, linked_file.from_import) array_add(*decls, decl);
                }
            } else { // We are adding all globals decls
                for decl: linked_file.file.declarations {
                    if is_global(decl, file, linked_file.file, linked_file.from_import) array_add(*decls, decl);
                }
            }
            unlock(*linked_file.file.mutex);
        }
    }

    // Scopes, Procedures ... (parents)
    // if from_block {

    if from_node {
        get_declarations_from_parent(*decls, from_node, from_loc, name, false);
    }
    // }

    // @TODO: Maybe deduplicate stuff here? (global stuff vs local shadowing etc)

    return decls;
}

get_node_nearest_parent :: (node: *Node, predicate: (Node.Kind) -> bool, limit := 15) -> *Node {
    current: *Node = node;
    i: int;

    while true {
        if predicate(current.kind) return current;

        if i >= limit break;
        i += 1;
        if !current.parent break;

        current = current.parent;
    }

    return null;
}

is_parent_of :: (parent: *Node, node: *Node, limit := 5) -> bool {
    if parent == node return true;

    current: *Node = node;
    i: int;

    while true {
        if current == parent return true;

        if i >= limit break;
        i += 1;
        if !current.parent break;

        current = current.parent;
    }

    return false;
}

is_global :: (node: *Node, from_file: *Program_File, it_file: *Program_File, from_import: bool) -> bool {
    if !node.parent return true;

    if node.parent.kind == .BLOCK {
        return is_global(node.parent, from_file, it_file, from_import);
    }

    // @TODO: Make this more robust!
    if node.parent.kind == .IF {
        _if := cast(*If) node.parent;
        if !_if.compile_time return false;
        return is_global(_if, from_file, it_file, from_import);
    }

    if node.parent.kind == .DIRECTIVE_SCOPE {
        directive_scope := cast(*Directive_Scope) node.parent;

        if directive_scope.scope_kind == .MODULE && !from_import return true;
        if directive_scope.scope_kind == .EXPORT return true;
        if directive_scope.scope_kind == .FILE && from_file == it_file return true;
    }

    return false;
}

get_files_that_use :: (target_file: *Program_File) -> []*Program_File {
    files: [..]*Program_File;

    for file: server.files {
        if !is_avaiable_from(file, target_file.path) continue;
        array_add(*files, file);
    }

    return files;
}

get_files_that_load :: (target_file: *Program_File) -> []*Program_File {
    files: [..]*Program_File;

    for file: server.files {
        if !is_avaiable_from(file, target_file.path, true) continue;
        array_add(*files, file);
    }

    return files;
}

is_avaiable_from :: (file: *Program_File, path: string, $loads_only := false) -> bool, bool {
    already_checked: [..]string;
    loaded, from_import := is_avaiable_from_impl(file, path, *already_checked, loads_only);
    array_free(already_checked);
    return loaded, from_import;
}

is_avaiable_from_impl :: (file: *Program_File, path: string, already_checked: *[..]string, $loads_only := false) -> bool, bool {
    from_import: bool;
    loaded: bool;

    #if !loads_only {
        for file.imports {
            if array_find(already_checked.*, it.root) continue;
            array_add(already_checked, it.root);

            if it.root == path {
                from_import = true;
                loaded = true;
                break;
            }

            next_file := get_file(it.root);
            if !next_file continue;

            found: bool;
            found = is_avaiable_from_impl(next_file, path, already_checked, false);

            if found {
                from_import = true;
                loaded = true;
                break;
            }
        }
    }

    for file.loads {
        load_path := trim_right(path_strip_filename(file.path), "/");
        load_relative_path := normalize_path(join(load_path, "/", it.file));

        if array_find(already_checked.*, load_relative_path) continue;
        array_add(already_checked, load_relative_path);

        if load_relative_path == path {
            loaded = true;
            break;
        }

        next_file := get_file(load_relative_path);
        if next_file && is_avaiable_from_impl(next_file, path, already_checked, loads_only) {
            loaded = true;
            break;
        }
    }

    return loaded, from_import;
}

get_node_nearest_block :: (node: *Node) -> *Block {
    current_node := node;

    while current_node.parent {
        current_node = current_node.parent;
        if current_node.kind == .BLOCK {
            return cast(*Block) current_node;
        }
    }

    return null;
}

is_child_of_block :: (block: *Block, node: *Node, ignore_scoping := false) -> bool {
    if !block || !node return false;

    current_node := node;

    if current_node == block return true;

    while current_node.parent {
        current_node = current_node.parent;

        if !ignore_scoping && current_node.kind != .BLOCK && current_node.kind != .IF && current_node.kind != .CASE && current_node.kind != .FOR && current_node.kind != .WHILE {
            return false;
        }

        if current_node == block return true;
    }

    return true;
}

contains :: (a: Node.Location, b: Node.Location) -> bool {
    if a.l0 > b.l0 return false;
    if a.l1 < b.l1 return false;

    if a.l0 == b.l0 && a.c0 > b.c0 return false;
    if a.l1 == b.l1 && a.c1 < b.c1 return false;

    return true;
}

is_after :: (a: Node.Location, b: Node.Location) -> bool {
    if b.l0 > a.l1 return true;
    if b.c0 > a.c1 return true;
    return false;
}

lsp_location_to_node_location :: (location: LSP_Position, file := "") -> Node.Location {
    node_location: Node.Location;
    node_location.file = file;
    node_location.l0 = location.line;
    node_location.c0 = location.character;
    node_location.l1 = location.line;
    node_location.c1 = location.character;
    return node_location;
}

node_location_to_lsp_location :: (location: Node.Location) -> LSP_Location {
    lsp_location: LSP_Location;
    lsp_location.uri = path_to_lsp_path(location.file);
    lsp_location.range.start.line = xx location.l0;
    lsp_location.range.start.character = xx location.c0;
    lsp_location.range.end.line = xx location.l1;
    lsp_location.range.end.character = xx location.c1;
    return lsp_location;
}

get_identifier_decls :: (ident: *Identifier) -> []*Declaration {
    file := get_file(ident.location.file);
    if !file {
        return .[];
    }

    return get_declarations(file, ident, *ident.location, ident.name);
}

select_first_decl :: (decls: []*Declaration, level: int) -> *Declaration {
    if decls.count == 0 {
        return null;
    }

    return decls[0];
}

get_node_type :: (root: *Node, solve_array := false, select_decl := select_first_decl, stop_at_procedure := false) -> *Node {
    current_node: *Node = root;

    level: int;
    while true {
        defer level += 1;
        if !current_node break;

        // log("Resolving type: % (%:%:%)", current_node.kind, current_node.location.file, current_node.location.l0, current_node.location.c0);

        if current_node.kind == .IDENTIFIER {
            ident := cast(*Identifier, current_node);
            ident_decls := get_identifier_decls(ident);

            if ident_decls.count == 0 {
                return current_node;
            }

            current_node = select_decl(ident_decls, level);

            continue;
        }

        // Follow declaration to its type expression — resolves variables
        // like `engine: Engine` to the struct definition.
        if current_node.kind == .DECLARATION {
            decl := cast(*Declaration) current_node;
            if decl.type_inst {
                current_node = decl.type_inst;  continue;
            }
            if decl.expression {
                current_node = decl.expression;  continue;
            }
            break;
        }

        if current_node.kind == .STRUCT {
            return current_node;
        }

        if current_node.kind == .UNION {
            return current_node;
        }

        if current_node.kind == .ENUM {
            return current_node;
        }

        if current_node.kind == .DIRECTIVE_IMPORT {
            return current_node;
        }

        if current_node.kind == .ARRAY_SUBSCRIPT {
            array_subscript := cast(*Array_Subscript) current_node;
            current_node = array_subscript.expression;
            continue;
        }

        if current_node.kind == .ARRAY_TYPE {
            array_type := cast(*Array_Type, current_node);

            if solve_array {
                current_node = array_type.element_type;
                continue;
            } else {
                return array_type;
            }
        }

        if current_node.kind == .TYPE_INSTANTIATION {
            ti := cast(*Type_Instantiation) current_node;
            if ti.expression {
                current_node = ti.expression;
                continue;
            }

            break;
        }

        if current_node.kind == .LITERAL {
            literal := cast(*Literal) current_node;

            if literal.value_type == {
                case .STRUCT;
                    struct_literal_info := literal.values.struct_literal_info;
                    if struct_literal_info.type {
                        current_node = struct_literal_info.type;
                        continue;
                    }

                case .ARRAY;
                    array_literal_info := literal.values.array_literal_info;

                    if solve_array && array_literal_info.element_type {
                        current_node = array_literal_info.element_type;
                        continue;
                    } else {
                        return current_node;
                    }

                case;
                    return current_node;
            }
        }

        if current_node.kind == .DECLARATION {
            decl := cast(*Declaration) current_node;

            if decl.type_inst {
                current_node = decl.type_inst;
                continue;
            }

            if decl.expression {
                current_node = decl.expression;
                continue;
            }

        }

        if current_node.kind == .RETURN_VALUE {
            return_value := cast(*Return_Value) current_node;
            current_node = return_value.expression;
            continue;
        }

        if current_node.kind == .BINARY_OPERATION {
            bin_op := cast(*Binary_Operation)current_node;

            // DOT chains: walk the chain path (a.b.c → resolve fields in order)
            // Everything else (=, +=, ==, <, +, etc.): resolve left side's type
            if bin_op.operation == .DOT {
                path := get_dot_path(bin_op, null);
                current_node = get_path_type(path);
            } else if bin_op.left {
                if bin_op.left.kind == .BINARY_OPERATION {
                    path := get_dot_path(xx bin_op.left, null);
                    current_node = get_path_type(path);
                } else {
                    current_node = get_path_type(.[bin_op.left]);
                }
            } else {
                current_node = null;
            }

            continue;
        }

        if current_node.kind == .PROCEDURE_CALL {
            proc_call := cast(*Procedure_Call) current_node;
            current_node = proc_call.procedure;
            continue;
        }

        if current_node.kind == .PROCEDURE {
            proc := cast(*Procedure) current_node;

            if stop_at_procedure {
                return proc;
            }

            if proc.returns.count > 0 {
                current_node = proc.returns[0].expression;
                continue;
            }
        }

        if current_node.kind == .DIRECTIVE_TYPE {
            dt := cast(*Directive_Type) current_node;
            if dt.expression && dt.expression.kind == .PROCEDURE {
                current_node = dt.expression;
                continue;
            }

            break;
        }

        if current_node.kind == .DIRECTIVE_BAKE_ARGUMENTS {
            directive_bake_arguments := cast(*Directive_Bake_Arguments) current_node;
            if directive_bake_arguments.expression {
                current_node = directive_bake_arguments.expression;
                continue;
            }

            break;
        }

        if current_node.kind == .UNARY_OPERATION {
            unary_op := cast(*Unary_Operation) current_node;
            if unary_op.operation == .POINTER {
                current_node = unwrap_pointer(xx current_node);
                continue;
            }

            if unary_op.operation == .POINTER_DEREFERENCE {
                if !unary_op.expression {
                    break;
                }

                current_node = unary_op.expression;
                continue;
            }

            break;
        }

        if current_node.kind == .CAST {
            _cast := cast(*Cast) current_node;
            current_node = _cast.cast_expression;
            continue;
        }

        break;
    }

    return null;
}

unwrap_polymorphic_constant :: (node: *Node) -> *Node {
    if node.kind != .POLYMORPHIC_CONSTANT {
        return node;
    }

    const := cast(*Polymorphic_Constant) node;

    return const.expression;
}

// Extract name from a polymorphic parameter node.
// $packages: Type → Polymorphic_Constant(expression=Declaration(name="packages"))
// $T            → Polymorphic_Constant(expression=Identifier(name="T"))
get_polymorphic_param_name :: (arg: *Node) -> string {
    // Polymorphic args in a struct definition (declared as `struct (x: Type)`)
    // are stored as DECLARATION nodes.
    if arg.kind == .DECLARATION {
        decl := cast(*Declaration) arg;
        return decl.name;
    }

    if arg.kind != .POLYMORPHIC_CONSTANT return "";
    pc := cast(*Polymorphic_Constant) arg;
    if !pc.expression return "";
    if pc.expression.kind == .IDENTIFIER {
        ident := cast(*Identifier) pc.expression;
        return ident.name;
    }
    if pc.expression.kind == .DECLARATION {
        decl := cast(*Declaration) pc.expression;
        return decl.name;
    }
    return "";
}

// Given a Declaration's expression node, resolve through wrappers to find
// the underlying Struct, if any.
// Does NOT follow #bake_arguments — that calls arbitrary compile-time code
// (e.g. Mixer) and generates a NEW struct whose fields are opaque to static
// analysis. The template struct's fields are wrong and misleading.
find_struct_of_expression :: (expr: *Node) -> *Struct {
    if !expr return null;

    if expr.kind == .STRUCT {
        return cast(*Struct) expr;
    }

    if expr.kind == .DIRECTIVE_TYPE {
        dt := cast(*Directive_Type) expr;
        return find_struct_of_expression(dt.expression);
    }

    if expr.kind == .TYPE_INSTANTIATION {
        ti := cast(*Type_Instantiation) expr;
        return find_struct_of_expression(ti.expression);
    }

    if expr.kind == .PROCEDURE_CALL {
        resolved := get_node_type(expr);
        if resolved && resolved.kind == .STRUCT {
            return cast(*Struct) resolved;
        }
    }

    return null;
}


unwrap_pointer :: (unary_op: *Unary_Operation) -> *Node {
    if unary_op.operation != .POINTER return unary_op;

    // nested pointers
    if unary_op.expression.kind == .UNARY_OPERATION {
        return unwrap_pointer(xx unary_op.expression);
    }

    return unary_op.expression;
}

get_block_of :: (node: *Node) -> *Block {
    if node.kind == .BLOCK return cast(*Block) node;

    if node.kind == {
        case .STRUCT; return (cast(*Struct) node).block;
        case .ENUM;   return (cast(*Enum) node).block;
        case .UNION;  return (cast(*Union) node).block;
        case .PROCEDURE_CALL; {
            pc := cast(*Procedure_Call) node;
            if pc.procedure && pc.procedure.kind == .IDENTIFIER {
                pc_decls := get_identifier_decls(cast(*Identifier) pc.procedure);
                for d: pc_decls {
                    if d.expression && d.expression.kind == .STRUCT {
                        return (cast(*Struct) d.expression).block;
                    }
                }
            }
            return null;
        }
    }

    return null;
}

// This depends on Preload having this type. We need to keep this in sync with the compiler.
get_internal_array_struct :: (resizable: bool) -> *Struct {
    preload := search_for_file("modules/Preload.jai");
    if !preload {
        return null;
    }

    // @TODO: Array_View_64 is actually not correct type because data in it is type of *u8 and it should be *void.
    // Currently there is no plain Array_View with *void in Preload so we will keep it this way for now.
    // In the future we can put this builtins inside some "virtual" file.
    search_for := ifx resizable then "Resizable_Array" else "Array_View_64";

    ok, decl := table_find(*preload.declarations, search_for);
    if !ok || !decl.expression || decl.expression.kind != .STRUCT {
        return null;
    }

    return cast(*Struct) decl.expression;
}

// This depends on Preload having this type. We need to keep this in sync with the compiler.
get_internal_string_struct :: () -> *Struct {
    preload := search_for_file("modules/Preload.jai");
    if !preload {
        return null;
    }

    ok, decl := table_find(*preload.declarations, "Newstring");
    if !ok || !decl.expression || decl.expression.kind != .STRUCT {
        return null;
    }

    return cast(*Struct) decl.expression;
}

get_member_in :: (parent: *Node, ident: *Identifier) -> *Declaration {
    decls := get_members_in(parent, ident);
    if decls.count == 0 {
        return null;
    }

    return decls[0];
}

get_members_in :: (parent: *Node, ident: *Identifier) -> []*Declaration {
    decls: [..]*Declaration;

    if parent.kind == .DIRECTIVE_IMPORT {
        import := cast(*Directive_Import) parent;

        module_file_path := get_module_import_path(import, parent.location.file);
        module_file := get_file(module_file_path);

        if !module_file {
            return decls;
        }

        return get_declarations(module_file, only_loaded=true, name=ident.name);
    }

    // Special case for array
    if parent.kind == .ARRAY_TYPE {
        parent_array_type := cast(*Array_Type) parent;
        internal_array_struct := get_internal_array_struct(parent_array_type.resizable);
        if internal_array_struct {
            parent = internal_array_struct;
        }
    }

    // Special case for string
    parent_base_type := get_base_type_from_ident_or_literal(parent);
    if parent_base_type == .STRING {
        internal_string_struct := get_internal_string_struct();
        if internal_string_struct {
            parent = internal_string_struct;
        }
    }

    // Polymorphic struct instantiation: resolve Procedure_Call → Struct
    if parent.kind == .PROCEDURE_CALL {
        proc_call := cast(*Procedure_Call) parent;
        if proc_call.procedure && proc_call.procedure.kind == .IDENTIFIER {
            pc_decls := get_identifier_decls(cast(*Identifier) proc_call.procedure);
            for d: pc_decls {
                _struct := find_struct_of_expression(d.expression);
                if !_struct continue;

                // Check block members first
                if _struct.block {
                    block_member := get_block_member(_struct.block, ident);
                    if block_member {
                        array_add(*decls, block_member);
                    }
                }

                // Check polymorphic parameters — these become implicit fields
                // (e.g. struct($packages: Type) creates a `packages` field)
                if _struct.polymorphic_arguments.count > 0 {
                    for arg, arg_i: _struct.polymorphic_arguments {
                        param_name := get_polymorphic_param_name(arg);
                        if param_name.count > 0 && ident && ident.name == param_name {
                            // Create synthetic declaration for the polymorphic field
                            synth_decl := New(Declaration);
                            synth_decl.name = param_name;
                            synth_decl.const = false;
                            synth_decl.has_elsewhere = false;
                            // The corresponding argument in proc_call is the instantiated type
                            if arg_i < proc_call.arguments.count {
                                synth_decl.type_inst = proc_call.arguments[arg_i];
                            }
                            synth_decl.expression = d.expression;
                            array_add(*decls, synth_decl);
                        }
                    }
                }

                break;
            }
        }
        return decls;
    }

    block := get_block_of(parent);
    if !block {
        return decls;
    }

    block_member := get_block_member(block, ident);
    if !block_member {
        return decls;
    }

    array_add(*decls, block_member);

    return decls;
}

get_block_member_type :: (block: *Block, ident: *Identifier, solve_array := false) -> *Node {
    decl := get_block_member(block, ident);
    if !decl {
        return null;
    }

    return get_node_type(decl, solve_array);
}

get_block_member :: (block: *Block, ident: *Identifier) -> *Declaration {
    for member: block.members {
        if member.kind == {
            case .UNION;
                _union := cast(*Union)member;

                return get_block_member(_union.block, ident);
            case .IDENTIFIER;
                _ident := cast(*Identifier) member;
                if _ident.name == ident.name {
                    decl := New(Declaration); // @MEMORY: We should free this or it is temp?
                    decl.name = _ident.name;
                    decl.expression = *empty_identifier;
                    decl.location = _ident.location;
                    decl.const = true;

                    return decl;
                }
            case .DECLARATION;
                decl := cast(*Declaration) member;
                if decl.name == ident.name return xx member;

            case .DIRECTIVE_AS; #through;
            case .USING;
                used_expression := get_used_expression(member);
                if !used_expression || used_expression.kind != .DECLARATION && used_expression.kind != .IDENTIFIER {
                    continue;
                }

                used_type := get_node_type(used_expression);
                if used_type {
                    decl := get_member_in(used_type, ident);
                    if decl && decl.name == ident.name {
                        return decl;
                    }
                }

                if used_expression.kind == .DECLARATION {
                    used_decl := cast(*Declaration) used_expression;
                    if used_decl.name == ident.name {
                        return used_decl;
                    }
                }
        }
    }

    return null;
}

unwrap_as :: (node: *Node) -> *Node {
    if !node return null;

    if node.kind == .DIRECTIVE_AS {
        directive_as := cast(*Directive_As) node;

        if directive_as.expression && directive_as.expression.kind == .DIRECTIVE_AS {
            return unwrap_as(directive_as.expression);
        }

        return directive_as.expression;
    }

    return node;
}

// get type of `using`
get_used_expression :: (node: *Node) -> *Node {
    unwrapped_node := unwrap_as(node);

    if !unwrapped_node || unwrapped_node.kind != .USING return null;

    _using := cast(*Using) unwrapped_node;
    return unwrap_as(_using.expression);
}

get_used_type :: (node: *Node) -> *Node {
    used_expression := get_used_expression(node);
    if !used_expression return null;

    if used_expression.kind != .IDENTIFIER && used_expression.kind != .DECLARATION {
        return null;
    }

    return get_node_type(used_expression);
}

get_last_binary_op :: (first: *Binary_Operation) -> *Binary_Operation {
    current := first;

    while current.right && current.right.kind == .BINARY_OPERATION {
        current = cast(*Binary_Operation) current.right;
    }

    return current;
}

// !!! Can return null as last node !!!
// This procedure is designed to walk binary op from right to left.
// Its currently using `get_last_binary_op` to get the most right (ending) binary op.
get_dot_path :: (binary_op: *Binary_Operation, from: *Node) -> []*Node {
    path: [..]*Node;

    if binary_op.operation != .DOT {
        // log("binary_op.operation != .DOT -> %", to_string(binary_op));
        return path;
    }

    root_binary_op := ifx from == null then get_last_binary_op(binary_op) else binary_op;

    if root_binary_op.operation != .DOT {
        // log("root_binary_op.operation != .DOT -> %", to_string(root_binary_op));
        return path;
    }

    if !from {
        // Append even null nodes so we know we have empty "." entry (monster.items[0].)
        array_add(*path, root_binary_op.right);
        array_add(*path, root_binary_op.left);
    } else {
        if root_binary_op.right == from {
            array_add(*path, root_binary_op.right);
            array_add(*path, root_binary_op.left); // this cannot be null?
        } else if root_binary_op.left == from {
            array_add(*path, root_binary_op.left);
        } else {
            // log_error("left nor right is from"); // is this correct? Should we assert?
            return path;
        }
    }
    
    current_op: *Binary_Operation = root_binary_op;
    while current_op.parent && current_op.parent.kind == .BINARY_OPERATION {
        current_op = cast(*Binary_Operation, current_op.parent);

        if current_op.operation != .DOT {
            break;
        }

        if current_op.left array_add(*path, current_op.left);
    }
    
    array_reverse(path);

    return path;
}

get_path_type :: (path: []*Node, recursion_limit: s16 = 1024) -> *Node {
    current_type: *Node;
    resolved_nodes: int;

    if recursion_limit <= 0 {
        // Enforce some kind of limit to the recursive search, else we run the risk
        // of exhausting our stack and getting killed. A good way to test this is to do
        // a goto definition search on a context's field.
        log_error("Recurisve search limit reached, quitting search");
        return null;
    }

    for node: path {
        if !node break;

        if node.kind == {
            case .PROCEDURE_CALL; #through;
            case .ARRAY_SUBSCRIPT; #through;
            case .IDENTIFIER;
                identifier: *Identifier;
                solve_array: bool = false;

                if node.kind == .IDENTIFIER {
                    identifier = cast(*Identifier) node;
                } else if node.kind == .ARRAY_SUBSCRIPT {
                    array_subscript := cast(*Array_Subscript, node);
                    if !array_subscript.expression || array_subscript.expression.kind != .IDENTIFIER {
                        return null;
                    }

                    identifier = cast(*Identifier) array_subscript.expression;
                    solve_array = true;
                } else if node.kind == .PROCEDURE_CALL {
                    proc_call := cast(*Procedure_Call) node;
                    if !proc_call.procedure || proc_call.procedure.kind != .IDENTIFIER {
                        return null;
                    }

                    identifier = cast(*Identifier) proc_call.procedure;
                }

                if !current_type {
                    select_first_non_procedure_decl :: (decls: []*Declaration, level: int) -> *Declaration {
                        if level > 0 {
                            return select_first_decl(decls, level);
                        }

                        for decl: decls {
                            if decl.expression && decl.expression.kind == .PROCEDURE continue;

                            return decl;
                        }

                        return null;
                    }

                    ident_decls := get_identifier_decls(identifier);
                    selected_decl := select_first_non_procedure_decl(ident_decls, 0);
                    if selected_decl && selected_decl.type_inst {
                        if selected_decl.type_inst.kind == .TYPE_INSTANTIATION {
                            ti := cast(*Type_Instantiation) selected_decl.type_inst;
                            if ti.expression {
                                current_type = ti.expression;
                            }
                        } else if selected_decl.type_inst.kind == .PROCEDURE_CALL {
                            current_type = selected_decl.type_inst;
                        }
                    }

                    if !current_type {
                        current_type = get_node_type(identifier, solve_array, select_first_non_procedure_decl);
                    }

                    if !current_type {
                        break;
                    }

                    resolved_nodes += 1;
                    continue;
                }

                if current_type.kind == .DIRECTIVE_IMPORT {
                    decl := get_member_in(current_type, identifier);
                    if !decl {
                        break;
                    }

                    current_type = get_node_type(decl, solve_array);
                    resolved_nodes += 1;
                    continue;
                }

                if current_type.kind == .STRUCT {
                    _struct := cast(*Struct, current_type);
                    if !_struct.block {
                        break;
                    }

                    member_type := get_block_member_type(_struct.block, identifier, solve_array);
                    if !member_type {
                        // log_error("Failed to get member type for %", identifier.name);
                        break;
                    }

                    current_type = member_type;
                    resolved_nodes += 1;
                    continue;
                }

                // Polymorphic struct instantiation: type is a Procedure_Call
                // wrapping a struct with polymorphic_arguments. Route member
                // lookup through the struct's block.
                if current_type.kind == .PROCEDURE_CALL {
                    pc := cast(*Procedure_Call) current_type;
                    if pc.procedure && pc.procedure.kind == .IDENTIFIER {
                        pc_decls := get_identifier_decls(cast(*Identifier) pc.procedure);
                        pc_found: bool;
                        for d: pc_decls {
                            _struct := find_struct_of_expression(d.expression);
                            if _struct {

                                // Check block members first
                                if _struct.block {
                                    member_type := get_block_member_type(_struct.block, identifier, solve_array);
                                    if member_type {
                                        current_type = member_type;
                                        resolved_nodes += 1;
                                        pc_found = true;
                                        break;
                                    }
                                }

                                // Check polymorphic parameters — these become implicit fields
                                // (e.g. struct($packages: Type) creates `packages`)
                                if !pc_found && _struct.polymorphic_arguments.count > 0 {
                                    for arg, arg_i: _struct.polymorphic_arguments {
                                        param_name := get_polymorphic_param_name(arg);
                                        if param_name.count > 0 && identifier.name == param_name {
                                            // Resolve to the corresponding instantiated type
                                            if arg_i < pc.arguments.count {
                                                current_type = pc.arguments[arg_i];
                                                resolved_nodes += 1;
                                                pc_found = true;
                                                break;
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        if pc_found continue;
                    }
                    break;
                }

            case .LITERAL;
                current_type = node;
                resolved_nodes += 1;

            case .UNARY_OPERATION;
                _unary_op := cast(*Unary_Operation) node;
                if _unary_op.operation == .POINTER_DEREFERENCE {
                    if !_unary_op.expression {
                        break;
                    }

                    current_type = get_node_type(_unary_op.expression, true);
                    if !current_type {
                        break;
                    }

                    resolved_nodes += 1;
                }

            case .CAST;
                _cast := cast(*Cast) node;

                cast_type := _cast.cast_expression;
                if cast_type && cast_type.kind == .UNARY_OPERATION {
                    cast_type = unwrap_pointer(cast(*Unary_Operation) _cast.cast_expression);
                }

                if !cast_type {
                    break;
                }

                current_type = get_node_type(cast_type, true);
                if !current_type {
                    return null;
                }

                resolved_nodes += 1;
            case; // abort!
                return null;
        }
    }

    if current_type && current_type.kind == .IDENTIFIER && current_type.location.file.data != null {
        resolved := get_node_type(current_type);
        if resolved && resolved != current_type {
            return resolved;
        }
    }

    // We are unable to resolve whole path so the final type would be invalid.
    if path.count > resolved_nodes  {
        return null;
    }

    return current_type;
}

Base_Type :: enum {
    UNKNOWN;

    STRING;

    INT;
    S64;
    S32;
    S16;
    S8;
    U64;
    U32;
    U16;
    U8;

    FLOAT;
    FLOAT32;
    FLOAT64;

    BOOL;

    VOID;
}

get_base_type_from_ident_or_literal :: (node: *Node) -> Base_Type {
    if node.kind == .IDENTIFIER {
        ident := cast(*Identifier) node;

        if ident.name == {
            case "string";  return .STRING;

            case "int";     return .INT;
            case "s64";     return .S64;
            case "s32";     return .S32;
            case "s16";     return .S16;
            case "s8";      return .S8;
            case "u64";     return .U64;
            case "u32";     return .U32;
            case "u16";     return .U16;
            case "u8";      return .U8;

            case "float";     return .FLOAT;
            case "float32";   return .FLOAT32;
            case "float64";   return .FLOAT64;

            case "bool";      return .BOOL;

            case "void";      return .VOID;
        }

        return .UNKNOWN;
    }

    if node.kind == .LITERAL {
        literal := cast(*Literal) node;

        if literal.value_type == {
            case .INT;      return .INT;
            case .FLOAT;    return .FLOAT;
            case .STRING;   return .STRING;
            case .BOOL;     return .BOOL;
            case;           return .UNKNOWN;
        }
    }

    return .UNKNOWN;
}

is_same_type :: (a: *Node, b: *Node) -> bool {
    if !a || !b {
        return false;
    }

    // complex types (user defined) as Entity, Monster, Player...
    if a.kind != .IDENTIFIER && a.kind != .LITERAL || b.kind != .IDENTIFIER && b.kind != .LITERAL  {
        return a == b;
    }

    // likely base type as string, int...
    a_base_type := get_base_type_from_ident_or_literal(a);
    b_base_type := get_base_type_from_ident_or_literal(b);

    if a_base_type == .UNKNOWN || b_base_type == .UNKNOWN {
        return false;
    }

    return a_base_type == b_base_type;
}

// @TODO: vargs, polymorphic types
get_best_overload_for_procedure_call :: (procedures: []*Procedure, call: *Procedure_Call) -> int {
    if procedures.count < 2 {
        return 0;
    }

    current_best := 0;
    current_best_matched_args: u16 = 0;

    for procedure: procedures {
        matched_args: u16;

        if call.arguments.count > procedure.arguments.count {
            continue;
        }

        for call_arg, call_arg_index: call.arguments {
            arg := procedure.arguments[call_arg_index];

            call_arg_type := get_node_type(call_arg);
            arg_type := get_node_type(arg);

            // log("Arg [%]: caller (% - %), calle (% - %)", arg_index, to_string(call_arg_type), call_arg_type.kind, to_string(arg_type), arg_type.kind);

            if !is_same_type(arg_type, call_arg_type) {
                break call_arg;
            }

            matched_args += 1;
        }

        if matched_args > current_best_matched_args {
            current_best = it_index;
            current_best_matched_args = matched_args;
        }
    }

    return current_best;
}

inside_comment :: (location: Node.Location) -> bool {
    file := get_file(location.file);
    if !file {
        return false;
    }

    for comment: file.comments {
        // location start >= comment start
        if (location.l0 < comment.l1 || (location.l0 == comment.l1 && location.c0 < comment.c1)) {
              // location.end > comment.start
              if (location.l1 > comment.l0 || (location.l1 == comment.l0 && location.c1 > comment.c0)) {
                  return true;
              }
          }
    }

    return false;
}

is_dot_binary_op :: (node: *Node) -> bool {
    if !node {
        return false;
    }

    if node.kind != .BINARY_OPERATION {
        return false;
    }

    binary_op := cast(*Binary_Operation) node;
    if binary_op.operation != .DOT {
        return false;
    }

    return true;
}

compound_declaration_to_declarations :: (decls: *[..]*Declaration, comp_decl: *Compound_Declaration, filter_name: string = "") {
    type_or_value_expr: *Node;
    if comp_decl.type_inst {
        if comp_decl.type_inst.expression {
            type_or_value_expr = comp_decl.type_inst.expression;
        } else if comp_decl.type_inst.type_inst {
            type_or_value_expr = comp_decl.type_inst.type_inst;
        }
    }

    for comp_member: comp_decl.members {
        if comp_member.kind != .COMPOUND_DECLARATION_ITEM {
            continue;
        }

        comp_item := cast(*Compound_Declaration_Item) comp_member;
        if comp_item.item_kind != .DECLARATION || !comp_item.expression || comp_item.expression.kind != .IDENTIFIER {
            continue;
        }

        comp_item_ident := cast(*Identifier) comp_item.expression;

        if filter_name && filter_name != comp_item_ident.name {
            continue;
        }

        item_expr: *Node = *unknown_identifier_node;
        if type_or_value_expr {
            if type_or_value_expr.kind == .IDENTIFIER {
                item_expr = type_or_value_expr;
            }

            if type_or_value_expr.kind == .COMMA_SEPARATED_EXPRESSION {
                comma_sep_expr := cast(*Comma_Separated_Expression) type_or_value_expr;

                if comma_sep_expr.members.count > it_index {
                    item_expr = comma_sep_expr.members[it_index];
                }
            }

            if type_or_value_expr.kind == .PROCEDURE_CALL {
                proc_call := cast(*Procedure_Call) type_or_value_expr;

                proc_node := get_node_type(proc_call, stop_at_procedure = true);

                if proc_node.kind == .PROCEDURE {
                    proc := cast(*Procedure) proc_node;
                    
                    if it_index < proc.returns.count {
                        item_expr = proc.returns[it_index];
                    }
                }
            }
        }

        // @TODO: is this ok? Do we really wan't to create "virtual" decl here?
        decl := New(Declaration);
        decl.parent = comp_item_ident.parent;
        decl.location = comp_item_ident.location;
        decl.name = comp_item_ident.name;
        decl.expression = item_expr;

        array_add(decls, decl);
    }
}

// ── Build symbol harvesting ─────────────────────────────────────────
// After diagnostics compiles the project, parse .build/.added_strings_*.jai
// intermediate files. These contain #insert (and some #run) expansions
// with source-file mapping in comment headers. Injected declarations
// are visible to autocomplete, type resolution, and semantic tokens.

extract_generated_from :: (s: string) -> (bool, string, s64) {
    GENERATED_FROM :: "Generated from ";
    pos := find_index_from_left(s, GENERATED_FROM);
    if pos < 0 return false, "", 0;

    start := pos + cast(s64) GENERATED_FROM.count;
    col_pos := find_index_from_left(s, ":", start);
    if col_pos <= start return false, "", 0;

    file_path := slice(s, start, col_pos - start);
    if file_path.count == 0 return false, "", 0;

    line_rest := slice(s, col_pos + 1, s.count - col_pos - 1);
    if line_rest.count > 0 && line_rest[line_rest.count - 1] == #char "." {
        line_rest.count -= 1;
    }
    line_val, parse_ok := parse_int(*line_rest, s64);
    if !parse_ok return false, "", 0;

    return true, normalize_and_copy_path(file_path), line_val;
}

find_decl_at_line :: (file: *Program_File, line: s64) -> *Declaration {
    // Walk top-level declarations in the source file to find which
    // declaration's span contains the given line.
    for node: file.nodes {
        if node.kind != .DECLARATION continue;
        decl := cast(*Declaration) node;
        if decl.location.l0 <= line && decl.location.l1 >= line {
            return decl;
        }
    }
    return null;
}

harvest_build_symbols :: () {
    intermediate_path := server.intermediate_path;
    if intermediate_path.count == 0 {
        intermediate_path = ".build";
    }

    build_dir := join(server.project_root, intermediate_path, separator="/",, temp);
    if build_dir.count == 0 return;
    if !file_exists(build_dir) return;

    // Clear inserted_fields — intermediate file AST pool changes each cycle
    // Free all the member arrays first to avoid leaks
    for members: server.inserted_fields {
        array_free(members);
    }
    table_reset(*server.inserted_fields);

    for members, name: server.inserted_fields_by_name {
        array_free(members);
        if name.count > 0 free(name);
    }
    table_reset(*server.inserted_fields_by_name);

    for members: server.inserted_fields_by_type_id {
        array_free(members);
    }
    table_reset(*server.inserted_fields_by_type_id);

    for _, key: server.decl_type_ids {
        if key.count > 0 free(key);
    }
    table_reset(*server.decl_type_ids);

    build_files := file_list(build_dir, false,, temp);

    for name: build_files {
        if !begins_with(name, ".added_strings") continue;
        if !ends_with(name, ".jai") continue;

        full_path := normalize_path(join(build_dir, name, separator="/",, temp),, temp);
        if full_path.count == 0 continue;

        // Parse the intermediate file (force=false: skip if already parsed)
        parse_file(full_path, true, false, false);
        intermediate_file := get_file(full_path);
        if !intermediate_file continue;

        // Walk nodes + comments in source order.
        // Comments like "// #insert text. Generated from /path/file.jai:3."
        // precede the declarations they generated. Each marker sets the
        // current source file (+ line of the #insert in that file) for
        // subsequent declarations.
        comment_idx: int;
        current_source: string;
        current_line: s64;

        for node: intermediate_file.nodes {
            // Process all comments before this node's start line
            while comment_idx < intermediate_file.comments.count {
                cmt := intermediate_file.comments[comment_idx];
                if cmt.l0 > node.location.l0 break;

                found, source_path, insert_line := extract_generated_from(cmt.string_value);
                if found {
                    current_source = source_path;
                    current_line = insert_line;
                }
                comment_idx += 1;
            }

            if current_source.count == 0 continue;

            target_file := get_file(current_source);
            if !target_file continue;

            // ── Handle both simple and compound declarations ──────────────
            // Simple: "Jojo: int;"                    → .DECLARATION
            // Compound: "Jojo, Jojo_2, Jojo_3: int;" → .COMPOUND_DECLARATION

            if node.kind == .DECLARATION {
                decl := cast(*Declaration) node;

                // Inject into target file's declaration table
                lock(*target_file.mutex);
                table_add(*target_file.declarations, decl.name, decl);
                unlock(*target_file.mutex);

                // Find the source declaration this was generated for and record it
                source_decl := find_decl_at_line(target_file, current_line);
                if source_decl {
                    lock(*target_file.mutex);
                    entry_ptr, is_new := find_or_add(*server.inserted_fields, source_decl);
                    if is_new {
                        entry_ptr.allocator = context.default_allocator;
                    }
                    array_add(entry_ptr, decl);
                    unlock(*target_file.mutex);
                }
            } else if node.kind == .COMPOUND_DECLARATION {
                cd := cast(*Compound_Declaration) node;

                source_decl := find_decl_at_line(target_file, current_line);
                if source_decl {
                    lock(*target_file.mutex);
                    entry_ptr, is_new := find_or_add(*server.inserted_fields, source_decl);
                    if is_new {
                        entry_ptr.allocator = context.default_allocator;
                    }

                    for member: cd.members {
                        if member.kind != .COMPOUND_DECLARATION_ITEM continue;
                        cdi := cast(*Compound_Declaration_Item) member;
                        if !cdi.expression || cdi.expression.kind != .IDENTIFIER continue;
                        ident := cast(*Identifier) cdi.expression;
                        if ident.name.count == 0 continue;

                        // Create a synthetic declaration for each name
                        // in the compound (e.g., Jojo, Jojo_2, Jojo_3).
                        synth := New(Declaration);
                        synth.name = ident.name;
                        synth.const = false;
                        synth.has_elsewhere = false;
                        synth.type_inst = *empty_identifier;

                        array_add(entry_ptr, synth);
                    }

                    unlock(*target_file.mutex);
                }
            }
        }
    }
}
