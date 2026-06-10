VERSION :: "1.0.0";

MEMORY_DEBUG :: false;

Args :: struct {
    verbose: bool;
    profile: bool;
    jai_path: string;
    jai_exe_name: string;
}

User_Options :: struct {
    auto_insert_parentheses: bool;
    use_symbols_from_local_modules: bool;
}

Server :: struct {
    args: Args;
    quit := false;

    // This is from the config file
    local_modules: [..]string;
    roots: []string;
    build_root: string;
    intermediate_path: string;

    project_root: string;
    files: Table(string, *Program_File);
    files_to_be_analyzed: [..]*Program_File;

    // Deferred parsing: imports queued for background resolution
    shallow_parse: bool;
    follow_all_imports: bool;   // true=follow ALL #import (root file); false=only wrapped_in_decl (imported files)
    deferred_imports: [..]string;
    deferred_total: int;       // total queued for percentage calc
    deferred_processed: int;
    needs_reanalyze: bool;
    diagnostics_pending: bool;   // run diagnostics after message response sent
    token_busy: bool;            // rate-limit: skip if semantic tokens already processing
    progress_cycle: int;         // unique token per batch progress cycle
    skip_reanalyze: bool;        // init: skip get_files_that_use (O(n²) overhead, no existing files need reanalysis)

    files_mutex: Mutex;          // thread-safe access to server.files + server.files_to_be_analyzed
    deferred_mutex: Mutex;       // thread-safe access to server.deferred_imports
    parse_workers: int;          // 0 = auto (CPU count - 1)

    // Async worker pool — persistent threads, never spawn/join per batch
    worker_threads: [..]*Thread;
    num_workers: int;
    task_queue: [..]Task;
    task_queue_mutex: Mutex;
    task_signal_r: s32 = -1;     // workers poll this for new tasks
    task_signal_w: s32 = -1;     // main thread writes to signal workers
    done_pipe_r: s32 = -1;       // main thread polls for worker completions
    done_pipe_w: s32 = -1;       // workers write 1 byte when done
    busy_workers: int;           // tracks in-flight tasks; under task_queue_mutex

    // Async output queue — all lsp_send calls queue here; main thread flushes to stdout
    // in scheduler loop. Eliminates risk of worker holding stdout mutex during print()
    // while main thread blocks waiting to respond to LSP request (stdout pipe deadlock).
    output_queue: [..]string;
    output_queue_mutex: Mutex;

    // I/O thread — reads stdin continuously, queues messages, signals main thread
    io_thread: Thread;
    io_queue: [..]string;        // message bodies queued by I/O thread for main thread
    io_queue_mutex: Mutex;       // guards io_queue
    io_signal_r: s32 = -1;       // self-pipe read end (polled by main thread)
    io_signal_w: s32 = -1;       // self-pipe write end (signaled by I/O thread)

    memory_files_lock: Mutex;
    memory_files: Table(string, Mem_File); // @ToDo: Keep track of a modified flag per file

    previously_errored_file: string;

    diagnostics_metaprogram_path: string;

    user_options: User_Options;

    // Incremental analysis: process one file per scheduler loop iteration
    // to avoid blocking the main thread for seconds during get_file_links.
    analysis_pending: bool;       // true when analysis work remains
    analysis_index: int = -1;     // index into files_to_be_analyzed, -1 = not started
    preload_file: *Program_File;  // cached preload file (found once per batch)
    runtime_support_file: *Program_File; // cached runtime support file (found once per batch)

    // Harvested fields from #bake_arguments / #insert expansions
    // Maps source Declaration -> generated member Declarations from .added_strings files
    // Cleared and rebuilt each harvest cycle (intermediate file AST pool changes).
    inserted_fields: Table(*Declaration, [..]*Declaration);
    inserted_fields_by_name: Table(string, [..]*Declaration);
    inserted_fields_by_type_id: Table(u64, [..]*Declaration);
    decl_type_ids: Table(string, u64);
}

server: Server;

// @TODO: move this to somewhere else
is_hex_digit :: (c: u32) -> bool {
    return (c >= #char "a" && c <= #char "f") || (c >= #char "A" && c <= #char "F") || (c >= #char "0" && c <= #char "9");
}

// @TODO: move this to somewhere else
decode_url :: (url: string) -> string {
    out_url := copy_string(url);

    i, j: int;
    hex: [2]u8 = .[#char "0", #char "0"];

    while i < out_url.count {

        defer {
            i += 1;
            j += 1;
        }

        // Need at least 2 more chars for %XX escape
        if out_url[i] != #char "%" || i + 2 >= out_url.count {
            out_url[j] = out_url[i];
            continue;
        }

        if is_hex_digit(out_url[i+1]) && is_hex_digit(out_url[i+2]) {
            hex[0] = out_url[i+1];
            hex[1] = out_url[i+2];

            out_url[j] = xx string_to_int(xx hex, 16);
            i += 2;
        }


    }
    out_url.count = j;

    return out_url;
}

find_entry_file :: (root: string) -> string {

    contains_main_procedure :: (file: string) -> bool {
        content := read_entire_file(file);
        return contains(content, "main ::") || contains(content, "main::");
    }

    // @Fixme: This does not take the root into account!
    COMMON_MAIN_PATH :: string.["/src/main.jai", "main.jai"]; // Maybe build.jai ... etc?

    for path: COMMON_MAIN_PATH {
        if file_exists(join(root, path, separator = "/")) && contains_main_procedure(path) {
            return path;
        }
    }

    files := file_list(root, true);

    for file: files {
        if contains(file, "main.jai") && contains_main_procedure(file) {
            return replace(file, root, "");
        }
    }

    for file: files {
        if contains_main_procedure(file) {
            return replace(file, root, "");
        }
    }

    return ""; // TODO: What we gonna do when we do not find any?
}

#if OS == .WINDOWS {
    DEFAULT_JAI_EXE_NAME :: "jai.exe";
} else #if OS == .MACOS {
    DEFAULT_JAI_EXE_NAME :: "jai-macos";
} else #if OS == .LINUX {
    DEFAULT_JAI_EXE_NAME :: "jai-linux";
}

find_jai_path :: (executable_name: string) -> string, string {
    result: Process_Result;
    raw_path: string;
    err: string;

    #if OS == .WINDOWS {
        result, raw_path, err = run_command("where.exe", executable_name, capture_and_return_output=true);
        path_overwrite_separators(raw_path, #char "/");
        raw_path = trim(raw_path);
    } else {
        #if OS == .MACOS {
            result, raw_path, err = run_command("whereis", "-q", executable_name, capture_and_return_output=true);
        } else { // Linux does not have the -q argument.
            result, raw_path, err = run_command("whereis", executable_name, capture_and_return_output=true);
        }

        raw_path = replace(raw_path, tprint("%:", executable_name), "");
        raw_path = trim(raw_path);

        BUFFER_SIZE :: 4096;
        buf: [BUFFER_SIZE] u8;

        length := readlink(to_c_string(raw_path), buf.data, BUFFER_SIZE);
        if length > 0 {
            resolved_path := to_string(buf.data);
            if begins_with(resolved_path, "/") {
                raw_path = resolved_path;
            }
        }
    }

    if raw_path.count == 0 {
        #if OS == .MACOS || OS == .LINUX {
            if executable_name == "jai" return "", "";
            path, exe_name := find_jai_path("jai");
            return path, exe_name;
        }

        return "", "";
    }

    while contains(raw_path, "//") raw_path = replace(raw_path, "//", "/");
    path := split(raw_path, "/");

    pop(*path); // jai.exe or jai
    pop(*path); // bin

    return join(..path, separator="/"), executable_name;
}

Config_File :: struct {
    local_modules: []string;
    roots: []string;
    build_root: string;
    jai_path: string;
    intermediate_path: string;
    auto_insert_parentheses := true;
    use_symbols_from_local_modules := true;
}

load_config_file :: () {
    config_path := join(server.project_root, "/jails.json");
    if !file_exists(config_path) {
        log_error("Failed to find 'jails.json' in your project root. Tried: %", config_path);
        return;
    }
    log("Attempting to load config file: %", config_path);

    config_content := read_entire_file(config_path);

    ok, config := json_parse_string(config_content, Config_File);
    if !ok {
        log("Failed to parse config file %", config_path);
        return;
    }
    log("Loaded config file %", config_path);

    for config.local_modules {
        array_add_if_unique(*server.local_modules, it);
    }

    server.roots = config.roots;
    server.build_root = config.build_root;
    server.intermediate_path = config.intermediate_path;
    server.user_options.auto_insert_parentheses = config.auto_insert_parentheses;
    server.user_options.use_symbols_from_local_modules = config.use_symbols_from_local_modules;

    if config.jai_path.count > 0 {
        server.args.jai_path = config.jai_path;
    }
}

create_diagnostics_metaprogram :: () {
    METAPROGRAM_SOURCE := #run -> string {
        project_dir := join(path_strip_filename(#file), "..");
        metaprogram_dir := tprint("%/metaprogram", project_dir);
        return read_entire_file(tprint("%/jails_diagnostics.jai", metaprogram_dir));
    };

    jails_exe_dir := trim_right(path_strip_filename(get_path_of_running_executable()), "/");
    metaprogram_dir := sprint("%/metaprogram", jails_exe_dir);
    if !make_directory_if_it_does_not_exist(metaprogram_dir) {
        log_error("Failed to create metaprogram directory!");
        return;
    }

    metaprogram_source_file_path := tprint("%/jails_diagnostics.jai", metaprogram_dir);

    if !write_entire_file(metaprogram_source_file_path, METAPROGRAM_SOURCE) {
        log_error("Failed to create metaprogram file!");
        return;
    }

    server.diagnostics_metaprogram_path = metaprogram_dir;
    log("Metaprogram file created! (%)", metaprogram_source_file_path);
}

get_root_from_initialization :: (body: LSP_Request_Message_Initialize) -> (bool, string) {
    if body.params.workspaceFolders != null && body.params.workspaceFolders.count > 0 {
        log("Workspace folders: %", body.params.workspaceFolders.*);
        uri: string = body.params.workspaceFolders.*[0].uri;
        if (uri.count > 0) {
            return true, normalize_and_copy_path(uri);
        }
    }

    if body.params.rootUri != null {
        log("Root URI: %", body.params.rootUri.*);
        uri := body.params.rootUri.*;
        if (uri.count > 0) {
            return true, normalize_and_copy_path(uri);
        }
    }

    if body.params.rootPath != null {
        log("Root Path: %", body.params.rootPath.*);
        uri := body.params.rootPath.*;
        if (uri.count > 0) {
            return true, normalize_and_copy_path(uri);
        }
    }

    return false, "";
}

// ── Request Handler ─────────────────────────────────────────────────────
// @TODO: Refactor into method dispatch table — Handler_Proc type + HANDLERS map.
// Currently uses inline switch for simplicity; each case should become a
// dedicated handle_XXX function registered at init time.

handle_request :: (request: LSP_Request_Message, raw_request: string) {
    // log("Got %", request.method);

    if request.method == {
        case "shutdown";
            server.quit = true;
            lsp_respond(request.id, null);
        case "initialize";
            success, body := json_parse_string(raw_request, LSP_Request_Message_Initialize,, temp);
            if !success {
                log_error("Unable to parse initialize message");
                // @Incomplete: report error back!
                return;
            }

            create_diagnostics_metaprogram();

            // The order of precedence for establishing our project_root is:
            // - workspaceFolder (initially we only use the first path specified)
            // - rootUri
            // - rootPath
            // - cwd

            gotRootFromInitialization, rootFromInitialization := get_root_from_initialization(body);
            if gotRootFromInitialization {
                server.project_root = rootFromInitialization;
            } else {
                log_error("Unable to determine the project root!");

                cwd := get_working_directory();
                if (cwd.count > 0) {
                    // This isn't inherently erroneous, but this is useful info for the error log.
                    log_error("Falling back to the current working directory as the project root.");
                    server.project_root = normalize_and_copy_path(cwd);
                } else {
                    log_error("Unable to fallback to the current working directory as the project root. Exiting.");
                    return;
                }
            }

            log("Project Root: %", server.project_root);
            load_config_file();

            if server.build_root.count == 0 {
                server.build_root = find_entry_file(server.project_root);
            }

            if server.roots.count == 0 {
                server.roots = .[find_entry_file(server.project_root)];
            }

            // Include $workingDirectory/modules as a default local module path (like a compiler)
            array_add_if_unique(*server.local_modules, "modules");

            log("Server.local_modules: %", server.local_modules);
            log("Server.roots: %", server.roots);
            log("Server.intermediate_path: %", server.intermediate_path);

            // Init mutexes for parallel deferred import processing
            init(*server.files_mutex);
            init(*server.deferred_mutex);

            // Parse Runtime Support and Preload (needed for built-in type resolution)
            server.skip_reanalyze = true;
            defer server.skip_reanalyze = false;
            {
                    log("INIT: parsing Runtime_Support...");
                parse_file(tprint("%/modules/Runtime_Support.jai", server.args.jai_path), true);
                log("INIT: parsing Preload...");
                parse_file(tprint("%/modules/Preload.jai", server.args.jai_path), true);

                log("INIT: parsing roots...");
                for root: server.roots {
                    root_path := join(server.project_root, root, separator="/");
                    if root_path.count > 0 {
                        log("INIT: parsing root: %", root_path);
                        parse_file(root_path, false, true, true);
                    }
                }
            }

            log("INIT: analyze_files...");
            analyze_files();

            log("INIT: respond...");
            to_send: LSP_Result_Initialize;
            lsp_respond(body.id, to_send);

        case "textDocument/definition";
            success, body := json_parse_string(raw_request, LSP_Request_Message_Definition,, temp);
            if !success {
                log_error("Unable to parse textDocument/definition message");
                return;
            }

            handle_goto(body);

        case "textDocument/didSave";
            success, body := json_parse_string(raw_request, LSP_Did_Save_Text_Document,, temp);
            if !success {
                log_error("Unable to parse textDocument/divSave message");
                return;
            }

            server.diagnostics_pending = true;

            file_path := normalize_path(body.params.textDocument.uri,, temp);

            // Full re-parse + incremental analysis (non-blocking, scheduler loop)
            parse_file(file_path, true);
            finish_analysis_if_complete();

        case "textDocument/didOpen";
            success, body := json_parse_string(raw_request, LSP_Did_Open_Text_Document,, temp);
            if !success {
                log_error("Unable to parse textDocument/didOpen message");
                return;
            }

            file_path := normalize_path(body.params.textDocument.uri,, temp);

            content := body.params.textDocument.text;

            create_memory_file(file_path, content);

            // Synchronous parse: follow all imports recursively so transitive
            // dependencies (Jay_Core, sgpu, etc.) are in server.files before
            // completion/semantic-token handlers fire. Background analysis
            // in process_analysis_step still populates linked_files later.
            parse_file(file_path, true);  // force=true, shallow=false (default), follow_all=true (default)

            // Re-parse loader files so their imports cascade transitively.
            // When package.jai (no imports) is opened, module.jai (which loads
            // it) needs re-parsing with follow_all=true so #import "Jay_Core"
            // resolves — otherwise Jay_Core symbols never appear.
            // NOTE: collect loader paths first, iterate after — parse_file
            // may allocate on `temp` and corrupt snapshot memory.
            // Parse loaders: files that #load the opened file.
            // First check already-parsed files (from previous init passes).
            {
                loader_paths: [..]string;
                loader_paths.allocator = context.default_allocator;
                lock(*server.files_mutex);
                for f: server.files {
                    if !f || f.path == file_path continue;
                    loaded, _ := is_avaiable_from(f, file_path, true); // loads_only=true
                    if loaded {
                        array_add(*loader_paths, copy_string(f.path));
                    }
                }
                unlock(*server.files_mutex);
                for path: loader_paths {
                    log("Re-parsing loader '%' due to didOpen of '%'", path, file_path);
                    parse_file(path, true);
                    free(path);
                }
                array_free(loader_paths);
            }

            // Also parse any pending deferred imports synchronously so loader
            // files (parsed shallowly during init) are available for immediate
            // completions. Workers pick up remaining deferred imports later.
            lock(*server.deferred_mutex);
            pending_paths: [..]string;
            pending_paths.allocator = context.default_allocator;
            for defer_path: server.deferred_imports {
                array_add(*pending_paths, copy_string(defer_path));
            }
            array_reset(*server.deferred_imports);
            unlock(*server.deferred_mutex);
            for defer_path: pending_paths {
                parse_file(defer_path, false, true, false); // shallow=true, follow_all=false
                free(defer_path);
            }
            array_free(pending_paths);

            // Disk-based loader discovery: if the opened file wasn't found as
            // a load target of any already-parsed file, check if a module.jai
            // exists in the same directory. Jai convention: module.jai loads
            // all files in its module (e.g. #load "pool.jai").
            // This handles the case where the import chain from roots doesn't
            // reach the module (e.g. sgpu/module.jai is never parsed during
            // init because no root file imports it).
            module_dir := path_strip_filename(file_path);
            module_path := normalize_path(join(module_dir, "/module.jai"));
            if get_file(module_path) == null && file_exists(module_path) {
                log("DISK_LOADER: parsing module.jai from disk: %", module_path);
                parse_file(module_path, true);
            }

            server.needs_reanalyze = true;

            // Run diagnostics after initial indexing so compiler-harvested
            // #insert/#bake_arguments completions are available without an
            // initial manual save. Scheduler waits for import workers to idle.
            server.diagnostics_pending = true;

            log("File_path: %", file_path);

        case "textDocument/didChange";
            success, body := json_parse_string(raw_request, LSP_Did_Change_Text_Document,, temp);
            if !success {
                log_error("Unable to parse textDocument/didChange message");
                return;
            }

            file_path := normalize_path(body.params.textDocument.uri,, temp);
            edit_memory_file(file_path, body.params.contentChanges);
            // Full parse (not shallow) — marks file for re-analysis; scheduler loop
            // handles incremental link resolution one file at a time.
            parse_file(file_path, true);
            finish_analysis_if_complete();

        case "textDocument/documentSymbol";
            success, body := json_parse_string(raw_request, LSP_Request_Message_Document_Symbol);
            if !success {
                log_error("Unable to parse textDocument/documentSymbol message");
                return;
            }

            log("workspace/documentSymbol");

            handle_document_symbol(body);

        case "workspace/symbol";
            success, body := json_parse_string(raw_request, LSP_Request_Message_Workspace_Symbol);
            if !success {
                log_error("Unable to parse workspace/symbol message");
                return;
            }

            log("workspace/symbol");

            handle_workspace_symbol(body);

        case "textDocument/didClose";
            success, body := json_parse_string(raw_request, LSP_Did_Close_Text_Document,, temp);
            if !success {
                log_error("Unable to parse textDocument/dicClose message");
                return;
            }

            file_path := normalize_path(body.params.textDocument.uri,, temp);
            remove_memory_file(file_path);

        case "textDocument/completion";
            success, body := json_parse_string(raw_request, LSP_Request_Message_Completion,, temp);
            if !success {
                log_error("Unable to parse textDocument/completion message");
                return;
            }

            handle_completitions(body);

        case "textDocument/signatureHelp";
            success, body := json_parse_string(raw_request, LSP_Request_Message_Signature_Help,, temp);
            if !success {
                log_error("Unable to parse textDocument/completion message");
                return;
            }

            handle_signature_help(body);

        case "textDocument/hover";
            // success, body := json_parse_string(raw_request, LSP_Request_Message_Hover,, temp);
            // if !success {
            //     log_error("Unable to parse textDocument/completion message");
            //     return;
            // }

            // handle_hover(body);

        case "textDocument/semanticTokens/full";
            success, body := json_parse_string(raw_request, LSP_Request_Message_SemanticTokens,, temp);
            if !success {
                log_error("Unable to parse textDocument/semanticTokens/full message");
                return;
            }

            handle_semantic_tokens_full(body);

        case "textDocument/semanticTokens/range";
            success, body := json_parse_string(raw_request, LSP_Request_Message_SemanticTokens_Range,, temp);
            if !success {
                log_error("Unable to parse textDocument/semanticTokens/range message");
                return;
            }

            handle_semantic_tokens_range(body);
    }
}

// ── Import dispatch (async worker pool) ────────────────────────────────
// Push deferred imports to worker queue up to batch size.
// Workers run persistently — main thread never blocks on join.
// Progress cycles per dispatch batch.

PARALLEL_BATCH :: 4;

dispatch_imports :: () {
    lock(*server.deferred_mutex);
    count := server.deferred_imports.count;
    unlock(*server.deferred_mutex);
    if count == 0 return;

    lock(*server.task_queue_mutex);
    already_busy := server.busy_workers;
    unlock(*server.task_queue_mutex);
    if already_busy >= server.num_workers return;



    batch_size := min(PARALLEL_BATCH, count);
    available := server.num_workers - already_busy;
    if batch_size > available batch_size = available;

    // Start or cycle progress
    if server.deferred_processed == 0 {
        lock(*server.deferred_mutex);
        server.deferred_total = server.deferred_imports.count;
        unlock(*server.deferred_mutex);
        server.progress_cycle = 0;
        send_progress_begin(tprint("jails-parse-%", server.progress_cycle), "Indexing",
            tprint("Parsing imports (%)", server.deferred_total));
    } else {
        send_progress_end(tprint("jails-parse-%", server.progress_cycle), "");
        server.progress_cycle += 1;
        send_progress_begin(tprint("jails-parse-%", server.progress_cycle), "Indexing",
            tprint("Parsing imports (%)", server.deferred_processed, server.deferred_total));
    }

    // Push tasks to worker queue (never spawn/join).
    // Tasks carry their own shallow flag — workers apply it locally.
    // deferred_mutex held for entire batch to prevent races with workers
    // concurrently adding new deferred imports during node_visit.
    lock(*server.deferred_mutex);
    for 0..batch_size-1 {
        path := server.deferred_imports[0];
        array_ordered_remove_by_index(*server.deferred_imports, 0);
        push_task(Task.{ type = .parse_import, file_path = path, shallow = true });
        server.deferred_processed += 1;
    }
    unlock(*server.deferred_mutex);
    server.needs_reanalyze = true;
}

finish_analysis_if_complete :: () {
    if server.analysis_pending return;  // still processing last batch, don't double-start

    lock(*server.deferred_mutex);
    remaining := server.deferred_imports.count;
    unlock(*server.deferred_mutex);
    if !server.needs_reanalyze || remaining > 0 return;

    lock(*server.task_queue_mutex);
    idle := server.busy_workers == 0;
    unlock(*server.task_queue_mutex);
    if !idle return;

    server.needs_reanalyze = false;
    server.deferred_total = 0;
    server.deferred_processed = 0;

    // Start incremental analysis (processes one file per scheduler loop iteration)
    if server.files_to_be_analyzed.count > 0 {
        process_analysis_step();  // kick off — processes first file
    } else {
        send_progress_end(tprint("jails-parse-%", server.progress_cycle), "Indexing complete");
        log("Background analysis complete");
    }
}

// ── Task types for async worker pool ────────────────────────────────────
// Workers pull tasks from a shared queue. For parse_batch, the worker spawns
// sub-threads (up to BATCH_SIZE) to process imports in parallel, then waits
// for all sub-threads before signaling completion to the main thread.

BATCH_SIZE :: 4;

Task_Type :: enum u32 {
    parse_import;   // single file: worker parses + spawns sub-workers for its imports
    parse_batch;    // batch of paths: spawns sub-workers for each
}

Task :: struct {
    type: Task_Type;
    file_path: string;   // for parse_import
    shallow: bool;       // run parse_file with shallow_parse=true
    batch_len: s32;      // number of valid paths in batch[] (0..BATCH_SIZE)
    batch: [BATCH_SIZE]string;  // paths for parse_batch (heap-allocated copies)
}

// ── Worker pool ─────────────────────────────────────────────────────────
// Push a task to the shared queue and signal one worker. Thread-safe.

push_task :: (task: Task) {
    lock(*server.task_queue_mutex);
    array_add(*server.task_queue, task);
    server.busy_workers += 1;
    unlock(*server.task_queue_mutex);

    // Signal one worker to wake up and grab the task
    sig: u8 = 0;
    write(cast(s32) server.task_signal_w, *sig, 1);
}

// Persistent worker thread procedure. Loops until quit: wait for signal,
// pop task from queue, execute, signal completion.

worker_proc :: (thread: *Thread) -> s64 {
    context.logger = lsp_log;
    fds: pollfd;
    fds.events = POLLIN;

    while !server.quit {
        // Block until task available or quit
        fds.fd = cast(s32) server.task_signal_r;
        poll(*fds, 1, -1);
        if server.quit break;

        // Drain signal byte
        sig: u8;
        read(cast(s32) server.task_signal_r, *sig, 1);

        // Pop task
        lock(*server.task_queue_mutex);
        if server.task_queue.count == 0 {
            unlock(*server.task_queue_mutex);
            continue;
        }
        task := server.task_queue[0];
        array_ordered_remove_by_index(*server.task_queue, 0);
        unlock(*server.task_queue_mutex);

        // Execute
        if task.type == .parse_import {
            // follow_all=false: restrict transitive import loading.
            // Bare #import (non-using) are recorded but NOT deferred here —
            // they are resolved when the file is re-parsed via didOpen
            // with shallow=false, follow_all=true (synchronous + transitive).
            parse_file(task.file_path, false, task.shallow, false); // imported → restrict transitive
            if task.file_path.count > 0 free(task.file_path);
        }

        reset_temporary_storage();

        // Signal completion — main thread polls done_pipe_r
        sig = 0;
        write(cast(s32) server.done_pipe_w, *sig, 1);
    }
    return 0;
}

// Spawn persistent worker threads at startup.
// Workers persist for the lifetime of the server — no per-batch spawn/join.

start_worker_pool :: () {
    num := server.parse_workers;
    if num <= 0 num = max(1, get_number_of_processors() - 1);
    server.num_workers = num;

    // Create pipes for task signaling and completion signaling
    #if OS != .WINDOWS {
        tfd: [2]s32;
        dfd: [2]s32;
        pipe(*tfd); pipe(*dfd);
        fcntl(tfd[0], F_SETFL, O_NONBLOCK);
        fcntl(dfd[0], F_SETFL, O_NONBLOCK);
        server.task_signal_r = tfd[0]; server.task_signal_w = tfd[1];
        server.done_pipe_r = dfd[0];   server.done_pipe_w = dfd[1];
    }

    for 0..num-1 {
        thread := New(Thread);
        thread_init(thread, worker_proc);
        thread_start(thread);
        array_add(*server.worker_threads, thread);
    }
}

// Drain completion pipe — decrement busy_workers for each completed task.

drain_completions :: () {
    sig: u8;
    count: int;
    while read(cast(s32) server.done_pipe_r, *sig, 1) > 0 {
        count += 1;
    }
    if count > 0 {
        lock(*server.task_queue_mutex);
        server.busy_workers -= count;
        unlock(*server.task_queue_mutex);
    }
}

// Flush queued output to stdout. Called from scheduler loop — never from workers.
// Swaps the queue with an empty array under lock, then writes all messages to stdout.
// Never holds lock during print(), so workers can queue messages concurrently.

flush_output_queue :: () {
    msgs: [..]string;
    msgs.allocator = context.default_allocator;

    lock(*server.output_queue_mutex);
    n := server.output_queue.count;
    if n > 0 {
        for 0..n-1 {
            array_add(*msgs, server.output_queue[it]);
        }
        server.output_queue.count = 0;
    }
    unlock(*server.output_queue_mutex);

    for msg: msgs {
        print("Content-Length: %\r\n\r\n%", msg.count, msg);
        free(msg);
    }
    array_free(msgs);
}

// ── I/O thread ──────────────────────────────────────────────────────────
// Dedicated thread that reads stdin continuously, queues raw message bodies,
// and signals the main thread via a self-pipe. This guarantees messages are
// received even while the main thread is blocked joining import workers.

io_thread_proc :: (thread: *Thread) -> s64 {
    while !server.quit {
        body, success := read_message_from_stdin(,, temp);
        if !success {
            if server.quit break;
            // EOF without quit -> client disconnected
            log("Stdin closed, shutting down");
            server.quit = true;
            break;
        }

        // Copy body to heap -- body's data is in this thread's temp storage.
        // context.allocator defaults to heap for spawned threads.
        body_copy := copy_string(body);

        // Queue for main thread
        lock(*server.io_queue_mutex);
        array_add(*server.io_queue, body_copy);
        unlock(*server.io_queue_mutex);

        // Reset temp storage to prevent unbounded growth
        reset_temporary_storage();

        // Signal main thread via self-pipe
        sig: u8 = 0;
        write(cast(s32) server.io_signal_w, *sig, 1);
    }
    return 0;
}

// ── I/O signaling via self-pipe ─────────────────────────────────────────
// Poll self-pipe read end instead of stdin. I/O thread writes one byte per
// queued message. Non-blocking peek: 0ms returns immediately, >0 waits up
// to N ms (acts as idle sleep when no messages pending).

io_wait :: (timeout_ms: s32) -> bool {
    #if OS != .WINDOWS {
        fds: pollfd;
        fds.fd = server.io_signal_r;
        fds.events = POLLIN;
        result := poll(*fds, 1, timeout_ms);
        return result > 0 && (fds.revents & POLLIN) != 0;
    }
    return false;  // Windows: always returns false (blocking behavior unchanged)
}

// ── Message drain ──────────────────────────────────────────────────────
// Dequeues ALL pending messages from the I/O thread's queue and processes
// them. Drains self-pipe signal bytes first, then processes messages.

drain_io_queue :: () {
    // Drain signal bytes from self-pipe (non-blocking)
    sig: u8;
    while read(server.io_signal_r, *sig, 1) > 0 {}

    // Process all queued messages
    while true {
        lock(*server.io_queue_mutex);
        if server.io_queue.count == 0 {
            unlock(*server.io_queue_mutex);
            break;
        }
        body := server.io_queue[0];
        array_ordered_remove_by_index(*server.io_queue, 0);
        unlock(*server.io_queue_mutex);

        parseOK, request := json_parse_string(body, LSP_Request_Message,, temp);
        if !parseOK {
            log_error("Unable to parse as json:\n%\n\n", body);
            free(body);
            continue;
        }
        handle_request(request, body);
        free(body);
        reset_temporary_storage();
    }
}

POLL_IDLE_MS :: 20;  // ms — idle wait before background work. poll() returns immediately when data arrives.

main :: () {
    context.logger = lsp_log;

    #if MEMORY_DEBUG defer {
        context.logger = runtime_support_default_logger;
        report_memory_leaks();
    }

    success: bool;
    success, server.args = parse_arguments(Args);
    if !success {
        log_error("Could not parse arguments");
        exit(1);
    }

    if server.args.jai_path.count == 0 {
        server.args.jai_path, server.args.jai_exe_name = find_jai_path(DEFAULT_JAI_EXE_NAME);
        if !server.args.jai_path {
            log_error("Failed to resolve Jai path");
            // @TODO: Send this fatal error over LSP somehow?
        } else {
            log("Jai path: % (%)", server.args.jai_path, server.args.jai_exe_name);
        }
    }

    log("Args are %", server.args);

    server.files_to_be_analyzed.allocator = context.default_allocator;

    // Async output queue — no mutex contention, flushed from scheduler loop
    server.output_queue.allocator = context.default_allocator;
    init(*server.output_queue_mutex);

    // Spawn I/O thread — reads stdin continuously, queues messages
    #if OS != .WINDOWS {
        pipe_fds: [2]s32;
        pipe(*pipe_fds);
        fcntl(pipe_fds[0], F_SETFL, O_NONBLOCK);
        server.io_signal_r = pipe_fds[0];
        server.io_signal_w = pipe_fds[1];
    }
    thread_init(*server.io_thread, io_thread_proc);
    thread_start(*server.io_thread);

    // Spawn persistent worker pool — never spawn/join per batch
    init(*server.task_queue_mutex);
    start_worker_pool();

    init_memory_files();

    // ── Cleanup on shutdown ──────────────────────────────────────────────
    defer {
        server.quit = true;

        // Wake I/O thread: signal pipe + close stdin to unblock read_from_stdin
        #if OS != .WINDOWS {
            sig: u8 = 0;
            write(cast(s32) server.io_signal_w, *sig, 1);
            for server.worker_threads {
                write(cast(s32) server.task_signal_w, *sig, 1);  // wake workers
            }
            close(0);
        }
        thread_deinit(*server.io_thread);
        for server.worker_threads {
            thread_deinit(it);
            free(it);
        }
        array_free(server.worker_threads);

        deinit_memory_files();
        deinit_inserted_fields();
        deinit_server_files();

        for path: server.deferred_imports {
            free(path);
        }
        array_free(server.deferred_imports);

        for task: server.task_queue {
            if task.file_path.count > 0 free(task.file_path);
        }
        array_free(server.task_queue);

        destroy(*server.files_mutex);
        destroy(*server.deferred_mutex);
        destroy(*server.io_queue_mutex);
        destroy(*server.task_queue_mutex);
        destroy(*server.output_queue_mutex);

        for msg: server.output_queue {
            free(msg);
        }
        array_free(server.output_queue);

        for body: server.io_queue {
            free(body);
        }
        array_free(server.io_queue);
        #if OS != .WINDOWS {
            close(server.io_signal_r); close(server.io_signal_w);
            close(server.task_signal_r); close(server.task_signal_w);
            close(server.done_pipe_r); close(server.done_pipe_w);
        }
    }

    // ── Scheduler loop ───────────────────────────────────────────────────
    // Poll both I/O pipe (new LSP messages) and completion pipe (workers done).
    // Dispatch deferred imports to worker pool when capacity available.
    // Never blocks on thread_deinit — workers run persistently.
    // Flush output queue after each phase to batch stdout writes safely.

    while !server.quit {
        #if OS != .WINDOWS {
            fds: [2]pollfd;
            fds[0].fd = cast(s32) server.io_signal_r;
            fds[0].events = POLLIN;
            fds[1].fd = cast(s32) server.done_pipe_r;
            fds[1].events = POLLIN;
            result := poll(fds.data, 2, POLL_IDLE_MS);

            if result > 0 {
                if fds[0].revents & POLLIN drain_io_queue();
                if fds[1].revents & POLLIN drain_completions();
            }
        } else {
            // Windows: poll not available, fall back to basic loop
            if io_wait(0) { drain_io_queue(); }
            Sleep(20);
        }

        flush_output_queue();

        // Dispatch deferred imports to async worker pool
        // Workers carry their own shallow flag; scheduler never toggles it.
        dispatch_imports();

        flush_output_queue();

        // Re-check for messages (more may have arrived during dispatch)
        if io_wait(0) {
            drain_io_queue();
        }

        // Check analysis complete (requires busy_workers == 0)
        finish_analysis_if_complete();

        // Incremental analysis: process files one-at-a-time, checking I/O
        // between each. This prevents blocking the main thread for seconds
        // when get_file_links iterates hundreds of server.files entries.
        while server.analysis_pending {
            process_analysis_step();
            flush_output_queue();
            if io_wait(0) {
                drain_io_queue();
                flush_output_queue();
            }
            if server.quit break;
        }

        flush_output_queue();

        // Run pending diagnostics when idle
        if server.diagnostics_pending {
            lock(*server.task_queue_mutex);
            idle := server.busy_workers == 0;
            unlock(*server.task_queue_mutex);
            if idle {
                server.diagnostics_pending = false;
                run_diagnostics();
            }
        }

    }

    // Flush any remaining output before exit — ensures shutdown response is sent
    flush_output_queue();
    // Don't call log() here — it would add to output_queue without flushing,
    // and the temp-allocated string data could be corrupted on exit.
    #if MEMORY_DEBUG {
        return;
    } else {
        exit(0);
    }
}

#import "Compiler";
#import "Basic"()(MEMORY_DEBUGGER=MEMORY_DEBUG);
#import "Print_Vars";
#import "Command_Line";
#import "File";
#import "File_Utilities";
#import "jaison";
#import "unicode_utils";
#import "String";
#import "Shared_Memory_Channel";
#import "Hash_Table";
#import "Random";
#import "Process";
#import "Reflection";
#import "Thread";
#import "Pool";
#import "jai_parser";
#import "Default_Allocator";
#import "System";

#load "rpc.jai";
#load "lsp_interface.jai";
#load "program.jai";
#load "diagnostics.jai";
#load "memory_files.jai";

#load "completition.jai";
#load "goto.jai";
#load "signature_help.jai";
#load "hover.jai";
#load "symbols.jai";
#load "semantic_tokens.jai";
#load "utils.jai";

#if OS == .WINDOWS {
    #import "Windows";
} else {
    #import "POSIX";
}
