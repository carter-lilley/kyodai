const { Resvg } = require('@resvg/resvg-js');
const sharp = require('sharp');
const fs = require('fs');
const path = require('path');

const ICONS_DIR = path.join(__dirname, '..', 'assets', 'platforms', 'icon');
const OUTPUT_SIZE = 256;

async function convertSvgToCroppedPng(svgPath, pngPath) {
  try {
    const svgString = fs.readFileSync(svgPath, 'utf8');
    
    const opts = {
      fitTo: {
        mode: 'width',
        value: OUTPUT_SIZE,
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
    
    const croppedWidth = maxX - minX + 1;
    const croppedHeight = maxY - minY + 1;
    
    await sharp(pngBuffer)
      .extract({ left: minX, top: minY, width: croppedWidth, height: croppedHeight })
      .toFile(pngPath);
    
    console.log(`Converted: ${path.basename(svgPath)} -> ${path.basename(pngPath)} (${croppedWidth}x${croppedHeight})`);
    return true;
  } catch (e) {
    console.log(`Error converting ${path.basename(svgPath)}: ${e.message}`);
    return false;
  }
}

async function main() {
  if (!fs.existsSync(ICONS_DIR)) {
    console.log(`Error: Directory ${ICONS_DIR} not found`);
    return;
  }
  
  const files = fs.readdirSync(ICONS_DIR).filter(f => f.endsWith('.svg')).sort();
  let converted = 0;
  
  for (const filename of files) {
    const svgPath = path.join(ICONS_DIR, filename);
    const pngFilename = filename.replace('.svg', '.png');
    const pngPath = path.join(ICONS_DIR, pngFilename);
    
    if (await convertSvgToCroppedPng(svgPath, pngPath)) {
      converted++;
    }
  }
  
  console.log(`\nConverted ${converted} icons`);
}

main().catch(console.error);
