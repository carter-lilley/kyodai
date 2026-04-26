package com.heckpoint.kyodai;

import androidx.core.content.FileProvider;

/**
 * Custom FileProvider for Kyodai to avoid manifest merger conflicts
 * with Godot's built-in FileProvider.
 */
public class KyodaiFileProvider extends FileProvider {
    // Empty - inherits all FileProvider behavior
}
