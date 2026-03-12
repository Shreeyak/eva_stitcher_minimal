---
description: "Rules for executing scripts and terminal commands"
applyTo: "**"
---

# Terminal Usage Rules

1. **NEVER USE HEREDOCS**: Never use `cat << 'EOF'` or `echo` to write scripts. Use a file tool like `create_file` or `replace_string_in_file` to create or modify scripts. Heredocs do not work in this environment and will break your workflow.
2. **USE FILE TOOLS**: To run a custom script, use the `create_file` tool to save it to `scripts/tmp_files/`, run it via the terminal, and then delete it.
3. **PYTHON IN-MEMORY**: If available, prefer using the Pylance `RunCodeSnippet` MCP tool to run Python code without writing to disk at all.
4. **NO OUTPUT SUPPRESSION**: Always let commands print full output. Do not use `| tail`, `| head`, `2>&1 | tail`, `> /dev/null`, or any output suppression.
5. Safe Replacement: If you need to modify an existing script, use `replace_string_in_file` to make targeted changes rather than rewriting the whole file. This minimizes risk of errors and preserves existing functionality.
6. If editing fails or a file appears corrupted, write intended contents to a new file, delete the original, then rename the new file to the original path. This ensures you always have a valid script and can recover if something goes wrong.
