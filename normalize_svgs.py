#!/usr/bin/env python3
"""
Normalize SVG viewBox to a consistent size (512x512) while preserving aspect ratio.
This script updates all SVG files to have the same viewBox dimensions.
"""

import os
import re
from pathlib import Path

SVG_DIR = Path("assets/platforms/icon")
TARGET_SIZE = 512.0

def parse_viewbox(content):
    """Extract viewBox values from SVG content."""
    # Match viewBox="x y width height" or viewBox='x y width height'
    match = re.search(r'viewBox=["\']([^"\']+)["\']', content)
    if not match:
        return None
    
    values = match.group(1).split()
    if len(values) != 4:
        return None
    
    try:
        return {
            'x': float(values[0]),
            'y': float(values[1]),
            'width': float(values[2]),
            'y': float(values[3])
        }
    except ValueError:
        return None

def normalize_svg(svg_path):
    """Normalize a single SVG file."""
    try:
        with open(svg_path, 'r', encoding='utf-8') as f:
            content = f.read()
        
        # Parse current viewBox
        match = re.search(r'viewBox=["\']([^"\']+)["\']', content)
        if not match:
            print(f"  [WARN] No viewBox found in {svg_path.name}")
            return False
        
        values = match.group(1).split()
        if len(values) != 4:
            print(f"  [WARN] Invalid viewBox format in {svg_path.name}")
            return False
        
        try:
            orig_width = float(values[2])
            orig_height = float(values[3])
        except ValueError:
            print(f"  [WARN] Invalid viewBox dimensions in {svg_path.name}")
            return False
        
        # Calculate scale to fit in TARGET_SIZE while preserving aspect ratio
        max_dim = max(orig_width, orig_height)
        scale = TARGET_SIZE / max_dim
        
        new_width = orig_width * scale
        new_height = orig_height * scale
        
        # Center in the target viewBox
        x_offset = (TARGET_SIZE - new_width) / 2.0
        y_offset = (TARGET_SIZE - new_height) / 2.0
        
        # Create the transform string
        transform = f'translate({x_offset:.6f}, {y_offset:.6f}) scale({scale:.6f})'
        
        # Strategy: Find the first <g> element and add the transform
        # Or wrap the content in a new group with the transform
        
        # Check if there's already a root <g> element
        g_match = re.search(r'(<svg[^\u003e]*>)([\s\S]*?)(</svg>)', content)
        if not g_match:
            print(f"  [WARN] Could not parse SVG structure in {svg_path.name}")
            return False
        
        svg_open = g_match.group(1)
        svg_content = g_match.group(2)
        svg_close = g_match.group(3)
        
        # Update the viewBox in the svg tag
        new_viewbox = f'0 0 {int(TARGET_SIZE)} {int(TARGET_SIZE)}'
        svg_open = re.sub(r'viewBox=["\'][^"\']+["\']', f'viewBox="{new_viewbox}"', svg_open)
        
        # Wrap content in a transform group
        new_content = f'{svg_open}\n  <g transform="{transform}"\u003e\n{svg_content}\n  </g>\n{svg_close}'
        
        # Write back
        with open(svg_path, 'w', encoding='utf-8') as f:
            f.write(new_content)
        
        print(f"  [OK] {svg_path.name:40s} {orig_width:8.1f} x {orig_height:8.1f} -> {int(TARGET_SIZE)} x {int(TARGET_SIZE)} (scale: {scale:.4f})")
        return True
        
    except Exception as e:
        print(f"  [ERR] Error processing {svg_path.name}: {e}")
        return False

def main():
    print(f"Normalizing SVGs to {int(TARGET_SIZE)}x{int(TARGET_SIZE)}...\n")
    
    svg_files = sorted(SVG_DIR.glob("*.svg"))
    success_count = 0
    
    for svg_file in svg_files:
        if normalize_svg(svg_file):
            success_count += 1
    
    print(f"\n{'='*60}")
    print(f"Success: {success_count}/{len(svg_files)} SVGs normalized")
    print(f"\nNote: You may need to restart Godot for changes to take effect.")
    print(f"The engine caches imported textures.")

if __name__ == "__main__":
    main()
