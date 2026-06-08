// This file contains code for running compiler for getting errors and warning.

reset_diagnostics :: () {
    if server.previously_errored_file {
        lsp_send(LSP_Client_Message(LSP_Publish_Diagnostics).{
            method="textDocument/publishDiagnostics",
            params = .{
                uri = server.previously_errored_file,
                diagnostics = LSP_Diagnostic.[]
            }
        });
    }
}

// Currently, parse only the first error (maybe parsing multiple errors is not that useful because Jai mostly report one error at a time)
// @TODO: Make it work with multiple errors
// @todo: add support for warnings
// ── Struct type info from compiler ──────────────────────────────────────
// Parse JAILS_DIAG_STRUCT lines emitted by the diagnostics metaprogram.
// compiler_report(.INFO) prepends file:line:col: Info: before the message,
// so we search for the marker anywhere in the line.
// Format: JAILS_DIAG_STRUCT|type_name|member_count|member1,member2,...
// Creates synthetic Declaration nodes in server.inserted_fields for
// #bake_arguments declarations whose instantiated struct name matches.

process_struct_dump :: (output: string) {
    MARKER :: "JAILS_DIAG_STRUCT|";

    if output.count == 0 {
        return;
    }

    lines := split(output, "\n",, temp);

    found: s64;
    for line: lines {
        marker_pos := find_index_from_left(line, MARKER);
        if marker_pos < 0 continue;
        found += 1;

        // Extract the data part (everything after the marker)
        data_part := slice(line, marker_pos, line.count - marker_pos);

        // Parse: JAILS_DIAG_STRUCT|name|count|mem1,mem2,mem3
        parts := split(data_part, "|",, temp);
        if parts.count < 4 continue;
        struct_name := parts[1];

        member_str := parts[3];
        member_names := split(member_str, ",",, temp);

        // Find a #bake_arguments declaration whose name matches this struct
        // (struct_name is e.g. "Packages(Jay_Render)" — match base name before "(")
        base_end := find_index_from_left(struct_name, "(");
        decl_name := struct_name;
        if base_end > 0 {
            decl_name = slice(struct_name, 0, base_end);
        }

        // Name-keyed cache for compiler-known struct fields. This covers
        // #insert expansions even when we cannot reliably map the dump back
        // to the exact source Declaration pointer.
        by_name_ok, _ := table_find(*server.inserted_fields_by_name, decl_name);
        if !by_name_ok {
            members_by_name: [..]*Declaration;
            members_by_name.allocator = context.default_allocator;
            for mname: member_names {
                if mname.count == 0 continue;
                sd := New(Declaration);
                sd.name = copy_string(mname);
                sd.const = true;
                sd.has_elsewhere = false;
                sd.type_inst = *empty_identifier;
                array_add(*members_by_name, sd);
            }
            table_add(*server.inserted_fields_by_name, copy_string(decl_name), members_by_name);
        }

        for file: server.files {
            for node: file.nodes {
                if node.kind != .DECLARATION continue;
                nd := cast(*Declaration) node;
                if nd.name != decl_name continue;

                matches_dump_source: bool;
                if nd.expression && nd.expression.kind == .DIRECTIVE_BAKE_ARGUMENTS {
                    matches_dump_source = true;
                } else if nd.expression {
                    source_struct := find_struct_of_expression(nd.expression);
                    if source_struct && source_struct.polymorphic_arguments.count > 0 {
                        matches_dump_source = true;
                    }
                }
                if !matches_dump_source continue;

                // Found matching declaration — add synthetic declarations
                lock(*file.mutex);
                // Skip if already processed (stdout and stderr may both have this)
                ok, _ := table_find(*server.inserted_fields, nd);
                    if !ok {
                        members: [..]*Declaration;
                        members.allocator = context.default_allocator;
                        for mname: member_names {
                            sd := New(Declaration);
                            sd.name = copy_string(mname);
                            sd.const = true;
                            sd.has_elsewhere = false;
                            sd.type_inst = *empty_identifier;
                            array_add(*members, sd);
                        }
                        table_add(*server.inserted_fields, nd, members);
                    }
                unlock(*file.mutex);
                break;
            }
        }
    }
}

run_diagnostics :: () {
    if server.build_root.count == 0 return;
    build_root_absolute := join(server.project_root, server.build_root, separator="/");
    defer free(build_root_absolute);

    log("Running diagnostics %", build_root_absolute);

    command: [..] string;
    defer array_free(command);

    jai_exe_path := DEFAULT_JAI_EXE_NAME;
    if server.args.jai_path.count > 0 {
        jai_exe_path = join(server.args.jai_path, "bin", server.args.jai_exe_name, separator="/",, temp);
    }

    array_add(*command, jai_exe_path);
    array_add(*command, build_root_absolute, "-quiet", "-no_color");

    // Use fast x64 backend on supported CPUs.
    if CPU == .X64 {
        array_add(*command, "-x64");
    }

    for local_module_folder: server.local_modules {
        array_add(*command, "-import_dir", local_module_folder);
    }

    array_add(*command, "+jails_diagnostics");

    if server.intermediate_path.count > 0 {
        joined := join(server.project_root, server.intermediate_path, separator="/",, temp);
        normalised := normalize_path(joined,, temp);
        array_add(*command, "-intermediate_path", normalised);
    }

    array_add(*command, "---", "import_dir", server.diagnostics_metaprogram_path);

    reset_diagnostics();

    // Capture both stdout and stderr — struct dump may be in either
    result, output, error := run_command(..command, working_directory=server.project_root, capture_and_return_output=true, timeout_ms=2500);

    has_struct_dump := contains(output, "JAILS_DIAG_STRUCT|") || contains(error, "JAILS_DIAG_STRUCT|");
    if result.exit_code == 0 || has_struct_dump {
        // Replace harvested completion cache only when the compiler produced
        // a usable struct dump. If the user saves with errors before that,
        // keep the last known good #insert/#bake_arguments completions.
        harvest_build_symbols();

        // Parse JAILS_DIAG_STRUCT| lines from compiler output.
        // These are emitted by the jails_diagnostics metaprogram for every struct
        // seen during type-checking, including #bake_arguments generated structs.
        // This populates server.inserted_fields so completions can show real fields
        // for baked types like Engine(Packages(Jay_Render)).
        process_struct_dump(output);
        process_struct_dump(error);
    }

    // ── Error reporting ──────────────────────────────────────────────
    if result.exit_code == 0 {
        if output.count > 0 free(output);
        if error.count > 0 free(error);
        return;
    }

    lines := split(error, "\n",, temp);

    file: string;
    diagnostic: LSP_Diagnostic;

    ERROR_MARKER :: ": Error:";
    // Get the first error
    for output_line: lines {
        if !contains(output_line, ERROR_MARKER) continue;

        message_index := find_index_from_right(output_line, ERROR_MARKER);
        message := slice(output_line, message_index + ERROR_MARKER.count, output_line.count - message_index);
        rest := slice(output_line, 0, message_index);

        ok: bool;
        location: string;
        ok, file, location = split_from_right(rest, ":");
        file = replace(file, "//", "/",, temp);
        if !ok continue;

        line_and_character := split(location, ",");
        if line_and_character.count < 2 continue;

        line, l_ok := parse_int(*line_and_character[0], u32);
        if !l_ok continue;

        character, c_ok := parse_int(*line_and_character[1], u32);
        if !c_ok continue;

        diagnostic.message = message;
        diagnostic.severity = xx LSP_Diagnostic_Severity.ERROR;

        diagnostic.range.start.line = line-1;
        diagnostic.range.start.character = character-1;
    }

    highlight_found := false;
    highlighted_chars: u32;

    for line: lines {
        if highlight_found || !contains(line, #char "^") continue;

        for char: cast([]u8) line {
            if char != #char "^" continue;
            highlighted_chars += 1;
        }

        highlight_found = true;
    }

    diagnostic.range.end.line = diagnostic.range.start.line;
    diagnostic.range.end.character = diagnostic.range.start.character+highlighted_chars;

    diagnostics: [1]LSP_Diagnostic;
    diagnostics[0] = diagnostic;

    file = path_to_lsp_path(normalize_path(file,, temp));

    lsp_send(LSP_Client_Message(LSP_Publish_Diagnostics).{
        method="textDocument/publishDiagnostics",
        params = .{
            uri = file,
            diagnostics = diagnostics
        }
    });

    old := server.previously_errored_file;
    server.previously_errored_file = copy_string(file);
    if file != old {
        free(old);
    }

    if output.count > 0 free(output);
    if error.count > 0 free(error);

}
