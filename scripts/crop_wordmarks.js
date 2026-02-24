const { Resvg } = require('@resvg/resvg-js');
const sharp = require('sharp');
const fs = require('fs');
const path = require('path');

const WORDMARKS_DIR = path.join(__dirname, '..', 'assets', 'platforms', 'wordmark');
const MAX_SIZE = 1024;

async function convertSvgToCroppedPng(svgPath, pngPath) {
  try {
    const svgString = fs.readFileSync(svgPath, 'utf8');
    
    // Parse SVG to get aspect ratio from viewBox (most reliable)
    const viewBoxMatch = svgString.match(/viewBox=["']([^"']+)["']/);
    let aspectRatio = 1;
    
    if (viewBoxMatch) {
      const viewBoxParts = viewBoxMatch[1].split(/\s+/);
      const vbWidth = parseFloat(viewBoxParts[2]);
      const vbHeight = parseFloat(viewBoxParts[3]);
      if (vbWidth > 0 && vbHeight > 0) {
        aspectRatio = vbWidth / vbHeight;
      }
    }
    
    // Render at high resolution (2048px) to ensure quality, then we'll scale down
    const renderSize = 2048;
    const opts = {
      fitTo: {
        mode: 'width',
        value: renderSize,
      },
    };
    
    const resvg = new Resvg(svgString, opts);
    const pngData = resvg.render();
    const pngBuffer = pngData.asPng();
    
    const image = sharp(pngBuffer);
    const { data, info } = await image
      .ensureAlpha()
      .raw()
      .toBuffer({ resolveWithObject: true });
    
    let minX = info.width;
    let minY = info.height;
    let maxX = 0;
    let maxY = 0;
    
    for (let y = 0; y < info.height; y++) {
      for (let x = 0; x < info.width; x++) {
        const idx = (y * info.width + x) * 4;
        const alpha = data[idx + 3];
        if (alpha > 10) {
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
        }
      }
    }
    
    if (maxX < minX) {
      console.log(`Warning: No visible pixels in ${path.basename(svgPath)}`);
      return false;
    }
    
    let croppedWidth = maxX - minX + 1;
    let croppedHeight = maxY - minY + 1;
    
    // Normalize to MAX_SIZE on longest edge
    const currentMaxDim = Math.max(croppedWidth, croppedHeight);
    const scale = MAX_SIZE / currentMaxDim;
    
    const finalWidth = Math.round(croppedWidth * scale);
    const finalHeight = Math.round(croppedHeight * scale);
    
    await sharp(pngBuffer)
      .extract({ left: minX, top: minY, width: croppedWidth, height: croppedHeight })
      .resize(finalWidth, finalHeight, { 
        fit: 'fill',
        kernel: sharp.kernel.lanczos3 
      })
      .toFile(pngPath);
    
    console.log(`Converted: ${path.basename(svgPath)} -> ${path.basename(pngPath)} (${finalWidth}x${finalHeight})`);
    return true;
  } catch (e) {
    console.log(`Error converting ${path.basename(svgPath)}: ${e.message}`);
    return false;
  }
}

async function main() {
  if (!fs.existsSync(WORDMARKS_DIR)) {
    console.log(`Error: Directory ${WORDMARKS_DIR} not found`);
    return;
  }
  
  const files = fs.readdirSync(WORDMARKS_DIR).filter(f => f.endsWith('.svg')).sort();
  let converted = 0;
  
  for (const filename of files) {
    const svgPath = path.join(WORDMARKS_DIR, filename);
    const pngFilename = filename.replace('.svg', '.png');
    const pngPath = path.join(WORDMARKS_DIR, pngFilename);
    
    if (await convertSvgToCroppedPng(svgPath, pngPath)) {
      converted++;
    }
  }
  
  console.log(`\nConverted ${converted} wordmarks`);
}

main().catch(console.error);
