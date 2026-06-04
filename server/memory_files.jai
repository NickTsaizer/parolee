Mem_File :: struct {
    content: [..]u8;
    line_offsets: [..]int; // byte offset of start of each line
}

init_memory_files :: () {
    init(*server.memory_files_lock);
}

deinit_memory_files :: () {
    destroy(*server.memory_files_lock);
    deinit(*server.memory_files);
}

compute_line_offsets :: (mf: *Mem_File) {
    array_reset(*mf.line_offsets);
    if mf.content.count == 0 return;
    array_add(*mf.line_offsets, 0); // line 0 always starts at index 0
    for i: 0 .. mf.content.count - 1 {  // Jai .. is inclusive
        if i + 1 < mf.content.count && mf.content[i] == #char "\n" {
            array_add(*mf.line_offsets, i + 1);
        }
    }
}

create_memory_file :: (file_path: string, content: string) {
    mf: Mem_File;
    array_copy(*mf.content, cast([]u8) content);
    compute_line_offsets(*mf);

    lock(*server.memory_files_lock);
    defer unlock(*server.memory_files_lock);

    // Free old file data if this file was already cached
    existing_ok, old_mf := table_find(*server.memory_files, file_path);
    if existing_ok {
        array_free(old_mf.content);
        array_free(old_mf.line_offsets);
    }

    table_set(*server.memory_files, copy_string(file_path), mf);
}

edit_memory_file :: (file_path: string, changes: []LSP_Content_Change) {
    lock(*server.memory_files_lock);
    defer unlock(*server.memory_files_lock);

    mf := table_find_pointer(*server.memory_files, file_path);
    if !mf {
        log_error("File is not in the cache %", file_path);
        return;
    }

    for change: changes {
        from := change.range.start;
        to := change.range.end;
        apply_change(*mf.content, from, to, change.text);
    }

    // Recompute line offsets after content mutation
    compute_line_offsets(mf);
}

remove_memory_file :: (file_path: string) {
    lock(*server.memory_files_lock);
    defer unlock(*server.memory_files_lock);

    ok, mf := table_find(*server.memory_files, file_path);
    if !ok return;
    array_free(mf.content);
    array_free(mf.line_offsets);

    found := table_remove(*server.memory_files, file_path);
    if !found {
        log_error("Tried to remove file % but it was not in the server.memory_files table!", file_path);
    }
}

find_range_in_memory_file :: (file: string, range: LSP_Range) -> string {
    lock(*server.memory_files_lock);
    defer unlock(*server.memory_files_lock);

    ok, mf := table_find(*server.memory_files, file);
    if !ok return "";

    offsets := mf.line_offsets;
    start_line := xx range.start.line;
    end_line := xx range.end.line;

    if start_line >= offsets.count || end_line >= offsets.count return "";

    start_index := offsets[start_line] + xx range.start.character;
    end_index := offsets[end_line] + xx range.end.character;

    if start_index >= mf.content.count || end_index > mf.content.count return "";
    return to_string(*mf.content[start_index], end_index - start_index);
}

find_line_in_memory_file :: (file: string, position: LSP_Position) -> string {
    lock(*server.memory_files_lock);
    defer unlock(*server.memory_files_lock);
    ok, mf := table_find(*server.memory_files, file);
    if !ok return "";

    line := xx position.line;
    offsets := mf.line_offsets;
    if line >= offsets.count return "";

    start_index := offsets[line];
    if start_index >= mf.content.count return "";

    // Find end of line (next newline or end of content)
    end_index := mf.content.count;
    i := start_index;
    while i < mf.content.count {
        if mf.content[i] == #char "\n" { end_index = i; break; }
        i += 1;
    }

    return to_string(*mf.content[start_index], end_index - start_index);
}

get_memory_file :: (name: string) -> []u8 {
    lock(*server.memory_files_lock);
    defer unlock(*server.memory_files_lock);

    ok, mf := table_find(*server.memory_files, name);
    if !ok return .[];

    return mf.content;
}

find_word_in_memory_file :: (file: string, position: LSP_Position, with_start_separator := false, with_end_separator := false) -> string {
    lock(*server.memory_files_lock);
    defer unlock(*server.memory_files_lock);
    ok, mf := table_find(*server.memory_files, file);
    if !ok return "";

    line := xx position.line;
    offsets := mf.line_offsets;
    if line >= offsets.count return "";

    pointer_index := offsets[line] + xx position.character;
    if pointer_index >= mf.content.count return "";

    content := mf.content;

    // Word search
    start_index := 0;
    end_index := content.count;

    is_seperation :: (char: u8) -> bool {
        return is_any(char, " \n\t;*.[](){}=:#\",!+-/");
    }

    // Start search
    for < index: 0 .. pointer_index {
        char := content[index];
        if is_seperation(char) {
            start_index = index;
            if !with_start_separator { start_index += 1; }
        }
    }

    // End search
    for index: pointer_index .. content.count - 1 {
        char := content[index];
        if is_seperation(char) {
            end_index = index;
            if !with_end_separator { end_index += 1; }
            break;
        }
    }

    return to_string(*content[start_index], end_index - start_index);
}

#scope_file

DEBUG_AC :: false;

// @todo:
// - unicode support
// Mutates in memory file
apply_change :: (content: *[..]u8, from: LSP_Position, to: LSP_Position, text: string) {
    current_line: int;
    current_char: int;
    start_index: int = -1;
    end_index: int = -1;

    curr: int;

    // We get index of starting and ending byte of the range.
    for char: content.* {

        if is_utf_cont(char) {
            curr += 1;
            continue;
        }

        if current_line == from.line && from.character == current_char {
            start_index = curr;
        }

        if current_line == to.line && to.character == current_char {
            end_index = curr;
        }

        if start_index > -1 && end_index > -1 {
            break;
        }

        curr += 1;
        current_char += 1;

        if char == #char "\n" {
            current_line += 1;
            current_char = 0;
        }
    }

    if start_index < 0 {
        start_index = content.count;
    }

    if end_index < 0 {
        end_index = content.count;
    }

    #if DEBUG_AC {
        log("from: %, to: % (reached line %)", from.line, to.line, current_line);

        log("- START (%)", start_index);

        builder: String_Builder;

        for start_index..end_index {
            char := (content.*)[it];
            print_to_builder(*builder, "%", to_string(*char, 1));
        }

        log("%", builder_to_string(*builder));

        log("- END (%) [%]", end_index, end_index-start_index);
    }

    assert(content.count >= start_index && content.count >= end_index);

    // Inserting only
    if start_index == end_index {
        for i: 0..text.count-1 {
            char := text[i];
            array_insert_at(content, char, start_index+i);
            #if DEBUG_AC log("inserting % at %", to_string(*char, 1), start_index + i);
        }
        return;
    }

    // Replace or delete
    text_index := 0;
    removed := 0;
    for start_index..end_index-1 {

        // When we are left with unprocessed range after insertion we delete it
        if text_index > text.count-1 {
            array_ordered_remove_by_index(content, it-removed);
            #if DEBUG_AC log("removing %", it-removed);
            removed += 1;
            continue;
        }

        (content.*)[it-removed] = text[text_index];
        text_index += 1;
    }

    // Insertion of leftovers (range is smaller than inserted content)
    if text_index < text.count {
        for index: 0..text.count - 1 - text_index {
            char := text[text_index + index];
            array_insert_at(content, char, end_index + index);

            #if DEBUG_AC log("inserting % at %", to_string(*char, 1), end_index + index);
        }
    }

}
