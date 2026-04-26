import re

file_path = r"C:\Users\carter\Documents\GitHub\kyodai\android\plugin\src\main\java\com\heckpoint\kyodai\PackageCheckerPlugin.java"

# Methods to remove (in order of appearance in file)
methods_to_remove = [
    "writeSafFile",
    "navigateToSafFile", 
    "extractSafZipToLocal",
    "createSafDirectoryFromPath",
    "extractVitaTitleIdFromSafZip",
    "readSafFileBytes",
    "readSafFileRange",
    "getSafFileSize",
    "copySafFileToLocal",
    "deleteSafDirectory"
]

with open(file_path, 'r', encoding='utf-8') as f:
    content = f.read()

# Find and remove each method
for method_name in methods_to_remove:
    # Find the method declaration
    # Look for patterns like: @UsedByGodot\n    public boolean writeSafFile(...
    # or: private DocumentFile navigateToSafFile(...
    # or: /**\n     * ...\n     */\n    @UsedByGodot\n    public ...
    
    # Try to find with Javadoc comment
    pattern_with_javadoc = r'(\n    /\*\*\n(?:.*?\n)*?\s+\*/\n)?\s*(@UsedByGodot\n)?\s*(?:private|public)\s+(?:boolean|String|long|byte\[\]|DocumentFile|void)\s+' + re.escape(method_name) + r'\([^)]*\)\s*\{'
    
    match = re.search(pattern_with_javadoc, content, re.DOTALL)
    
    if not match:
        # Try simpler pattern without javadoc
        pattern_simple = r'\s*(@UsedByGodot\n)?\s*(?:private|public)\s+(?:boolean|String|long|byte\[\]|DocumentFile|void)\s+' + re.escape(method_name) + r'\([^)]*\)\s*\{'
        match = re.search(pattern_simple, content, re.DOTALL)
    
    if not match:
        print(f"WARNING: Could not find method {method_name}")
        continue
    
    start = match.start()
    
    # Find the end of the method by tracking braces
    brace_depth = 0
    end = start
    found_first_brace = False
    
    for i in range(start, len(content)):
        if content[i] == '{':
            brace_depth += 1
            found_first_brace = True
        elif content[i] == '}':
            brace_depth -= 1
            if found_first_brace and brace_depth == 0:
                end = i + 1
                break
    
    # Include trailing whitespace/newlines up to next method or end of class
    while end < len(content) and content[end:end+2] == '\n\n':
        end += 1
    while end < len(content) and content[end] == '\n':
        end += 1
    
    # Remove the method
    content = content[:start] + content[end:]
    print(f"Removed method {method_name} ({end-start} chars)")

with open(file_path, 'w', encoding='utf-8') as f:
    f.write(content)

print("Done removing SAF methods")
