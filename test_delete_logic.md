## Delete Logic Test

You can test the deletion logic by adding a temporary test function to any GDScript file (like `main.gd`) and calling it from `_ready()`.

### Quick Test Script

Add this to `main.gd` or any active script:

```gdscript
func _ready():
    # Run the test (comment out when done)
    _test_delete_logic()

func _test_delete_logic():
    print("=== TESTING DELETE LOGIC ===")
    
    var test_dir = "user://test_delete_dir"
    var test_file = test_dir + "/test_file.txt"
    var nested_dir = test_dir + "/nested"
    var nested_file = nested_dir + "/nested_file.txt"
    
    # Create test directory structure
    DirAccess.make_dir_recursive_absolute(test_dir)
    DirAccess.make_dir_recursive_absolute(nested_dir)
    
    # Create test files
    var f = FileAccess.open(test_file, FileAccess.WRITE)
    f.store_string("test content")
    f.close()
    
    var f2 = FileAccess.open(nested_file, FileAccess.WRITE)
    f2.store_string("nested content")
    f2.close()
    
    print("Created test files at: " + test_dir)
    
    # Set read-only attributes (Windows only)
    if OS.get_name() == "Windows":
        # Set files to read-only using attrib
        OS.execute("cmd", ["/c", "attrib", "+r", test_file], [], true)
        OS.execute("cmd", ["/c", "attrib", "+r", nested_file], [], true)
        print("Set read-only attributes on test files")
    
    # Test delete_dir_recursive
    var success = FileSystemManager.delete_dir_recursive(test_dir)
    
    if success:
        print("✓ delete_dir_recursive succeeded")
    else:
        print("✗ delete_dir_recursive failed")
    
    # Verify deletion
    var still_exists = DirAccess.dir_exists_absolute(test_dir)
    if still_exists:
        print("✗ Directory still exists!")
        print("Remaining contents: " + str(FileSystemManager.list_dir(test_dir)))
    else:
        print("✓ Directory successfully removed")
    
    print("=== TEST COMPLETE ===")
```

### To Run:

1. Add the `_test_delete_logic()` call to `_ready()` in `main.gd`
2. Run the project from Godot editor
3. Check the Output panel for test results
4. Remove the test code when done

### Expected Results:

**Before fix (without attrib clearing):**
```
✗ delete_dir_recursive failed
✗ Directory still exists!
Remaining contents: [test_file.txt]
```

**After fix (with attrib clearing):**
```
✓ delete_dir_recursive succeeded
✓ Directory successfully removed
```

### Alternative: Manual Test via PowerShell

You can also test the raw logic outside Godot:

```powershell
# Create test directory
mkdir C:\temp\test_delete

# Create file and set read-only
"test" | Out-File C:\temp\test_delete\file.txt
attrib +r C:\temp\test_delete\file.txt

# Try to delete (this should fail without clearing attrib first)
Remove-Item C:\temp\test_delete -Recurse -Force
# ^ This works because -Force bypasses read-only

# To simulate Godot's behavior:
attrib -r C:\temp\test_delete\file.txt
Remove-Item C:\temp\test_delete -Recurse
```

The Godot test above mimics what happens during PS3 extraction cleanup.