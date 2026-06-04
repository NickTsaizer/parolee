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
                parse_file(tprint("%/modules/Runtime_Support.jai", server.args.jai_path), true);
                parse_file(tprint("%/modules/Preload.jai", server.args.jai_path), true);
            }

            analyze_files();

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

            parse_file(file_path, true);
            analyze_files();

        case "textDocument/didOpen";
            success, body := json_parse_string(raw_request, LSP_Did_Open_Text_Document,, temp);
            if !success {
                log_error("Unable to parse textDocument/didOpen message");
                return;
            }

            file_path := normalize_path(body.params.textDocument.uri,, temp);

            content := body.params.textDocument.text;

            create_memory_file(file_path, content);

            // Shallow parse: current file only, imports deferred to background
            server.shallow_parse = true;
            parse_file(file_path, true);
            server.shallow_parse = false;
            server.needs_reanalyze = false;

            // Defer analyze_files until background import resolution completes
            // (skips expensive get_file_links scan — re-runs in main loop anyway)
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
            server.shallow_parse = true;
            parse_file(file_path, true);
            server.shallow_parse = false;
            analyze_files();

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

// ── Import batch processing ─────────────────────────────────────────────
// Process deferred imports in parallel batches (up to PARALLEL_BATCH files
// per call). Cycle progress after each batch so Neovim never blocks features
// behind a long-lived progress window.

PARALLEL_BATCH :: 4;

process_import_batch :: () {
    if server.deferred_imports.count == 0 return;

    batch_size := min(PARALLEL_BATCH, server.deferred_imports.count);

    if server.deferred_processed == 0 {
        server.deferred_total = server.deferred_imports.count;
        server.progress_cycle = 0;
        send_progress_begin(tprint("jails-parse-%", server.progress_cycle), "Indexing",
            tprint("Parsing imports (%)", server.deferred_total));
    }

    // Process batch in parallel
    process_batch_parallel(batch_size);

    // Cycle progress per batch: end old window with current token, start new one with fresh token.
    // Unique token per cycle avoids AstroLSP state confusion from rapid end→begin on same token.
    if server.deferred_imports.count > 0 {
        send_progress_end(tprint("jails-parse-%", server.progress_cycle), "");
        server.progress_cycle += 1;
        send_progress_begin(tprint("jails-parse-%", server.progress_cycle), "Indexing",
            tprint("Parsing imports (%)", server.deferred_processed, server.deferred_total));
    }
}

finish_analysis_if_complete :: () {
    if server.needs_reanalyze && server.deferred_imports.count == 0 {
        server.needs_reanalyze = false;
        analyze_files();
        server.deferred_total = 0;
        server.deferred_processed = 0;
        send_progress_end(tprint("jails-parse-%", server.progress_cycle), "Indexing complete");
        log("Background analysis complete");
    }
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

    defer deinit(*server.files);

    server.files_to_be_analyzed.allocator = context.default_allocator;

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

    init_memory_files();
    defer {
        // Phase-out: signal I/O thread and close stdin to unblock its read
        server.quit = true;
        #if OS != .WINDOWS {
            sig: u8 = 0;
            write(cast(s32) server.io_signal_w, *sig, 1);  // wake in case not on stdin
            close(0);                                        // unblock read_from_stdin
        }
        thread_deinit(*server.io_thread);

        deinit_memory_files();
        destroy(*server.files_mutex);
        destroy(*server.deferred_mutex);
        destroy(*server.io_queue_mutex);
        array_free(server.io_queue);
        #if OS != .WINDOWS {
            close(server.io_signal_r);
            close(server.io_signal_w);
        }
    }

    while !server.quit {
        // Phase 1: Check for pending messages (non-blocking peek).
        // If messages are queued, process them ALL before background work.
        if io_wait(0) {
            drain_io_queue();
            continue;  // skip background work — more messages may be imminent
        } else {
            // Phase 1b: No data — wait briefly for next message (acts as idle sleep).
            // This prevents busy-wait when the server is idle.
            if io_wait(POLL_IDLE_MS) {
                drain_io_queue();
                continue;  // skip background work — process messages first
            }
        }

        // Phase 2: Process one batch of deferred imports with shallow parse
        // (keep shallow_parse=true so workers defer transitive imports instead
        //  of deep-parsing; this keeps batches fast and responsive)
        server.shallow_parse = true;
        process_import_batch();
        server.shallow_parse = false;

        // Phase 2b: Re-check for messages — messages may have arrived during import processing
        if io_wait(0) {
            drain_io_queue();
            continue;
        }

        // Phase 3: Re-analyze when all deferred imports are done
        finish_analysis_if_complete();

        // Phase 3b: Re-check — messages may have arrived during analysis
        if io_wait(0) {
            drain_io_queue();
            continue;
        }

        // Phase 4: Run pending diagnostics
        if server.diagnostics_pending {
            server.diagnostics_pending = false;
            run_diagnostics();
        }

        #if MEMORY_DEBUG report_memory_leaks();
    }

    log("Shutdown");
    exit(0);
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

// ── Parallel deferred import processing (batch model) ──────────────────
// Processes up to BATCH_SIZE items per call using worker threads.
// Each batch is self-contained: spawn workers → wait → cleanup.
// Main loop returns between batches so LSP stays responsive.

Worker_Data :: struct {
    paths: [..]string;  // local copy — no shared access to deferred_imports during parallel work
}

parse_deferred_worker :: (thread: *Thread) -> s64 {
    data := cast(*Worker_Data) thread.data;
    for data.paths {
        parse_file(it);
    }
    return 0;
}

process_batch_parallel :: (batch_size: int) {
    num_workers := max(1, get_number_of_processors() - 1);
    if num_workers > batch_size num_workers = batch_size;

    items_per_worker := batch_size / num_workers;
    remainder := batch_size % num_workers;

    threads: [..]*Thread;
    start_idx: int;

    for 0..num_workers-1 {
        count := items_per_worker;
        if it < remainder count += 1;

        thread := New(Thread);
        data := New(Worker_Data);

        // Extract paths into local array — no shared access to deferred_imports
        for 0..count-1 {
            path := server.deferred_imports[start_idx + it];
            array_add(*data.paths, path);
        }
        thread.data = data;

        thread_init(thread, parse_deferred_worker);
        thread_start(thread);
        array_add(*threads, thread);
        start_idx += count;
    }

    for threads {
        thread_deinit(it);
        free(it.data);
        free(it);

        // Interleave message checks between worker completions.
        // Other workers continue running while main thread drains messages.
        // This keeps LSP responsive during long-running batches.
        if io_wait(0) {
            saved_shallow := server.shallow_parse;
            drain_io_queue();
            server.shallow_parse = saved_shallow;  // didOpen may have cleared it
        }
    }
    array_free(threads);

    // Remove processed items from queue
    for 0..batch_size-1 {
        array_ordered_remove_by_index(*server.deferred_imports, 0);
    }
    server.deferred_processed += batch_size;
    server.needs_reanalyze = true;
}
