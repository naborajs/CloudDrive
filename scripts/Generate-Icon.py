"""
Generate a 100% Microsoft Windows-compliant multi-resolution ICO file from PNG.
Creates uncompressed DIB entries for 16, 24, 32, 48, 64, 128 px and PNG for 256 px.
"""
import os
import struct
import io
from PIL import Image

def generate_ico(png_path, ico_path):
    src_im = Image.open(png_path).convert('RGBA')
    
    dib_sizes = [16, 24, 32, 48, 64, 128]
    entries = []
    
    for s in dib_sizes:
        resized = src_im.resize((s, s), Image.Resampling.LANCZOS)
        
        # 1. BITMAPINFOHEADER (40 bytes)
        biSize = 40
        biWidth = s
        biHeight = s * 2 # Doubled for XOR + AND mask
        biPlanes = 1
        biBitCount = 32
        biCompression = 0
        and_stride = ((s + 31) // 32) * 4
        and_size = and_stride * s
        xor_size = s * s * 4
        biSizeImage = xor_size + and_size
        biXPelsPerMeter = 0
        biYPelsPerMeter = 0
        biClrUsed = 0
        biClrImportant = 0
        
        header = struct.pack('<IIIHHIIIIII',
            biSize, biWidth, biHeight, biPlanes, biBitCount,
            biCompression, biSizeImage, biXPelsPerMeter, biYPelsPerMeter,
            biClrUsed, biClrImportant
        )
        
        xor_bytes = bytearray()
        and_bytes = bytearray()
        
        for y in range(s - 1, -1, -1):
            mask_row = 0
            bit_count = 0
            row_and_bytes = bytearray()
            for x in range(s):
                r, g, b, a = resized.getpixel((x, y))
                if a == 0:
                    xor_bytes.extend([0, 0, 0, 0])
                    mask_row = (mask_row << 1) | 1
                else:
                    xor_bytes.extend([b, g, r, a])
                    mask_row = (mask_row << 1) | 0
                bit_count += 1
                if bit_count == 8:
                    row_and_bytes.append(mask_row)
                    mask_row = 0
                    bit_count = 0
            if bit_count > 0:
                mask_row = mask_row << (8 - bit_count)
                row_and_bytes.append(mask_row)
            
            while len(row_and_bytes) % 4 != 0:
                row_and_bytes.append(0)
            and_bytes.extend(row_and_bytes)
            
        entry_data = header + bytes(xor_bytes) + bytes(and_bytes)
        entries.append((s, s, entry_data))
        
    # 256x256 as PNG (Windows Vista/7/8/10/11 standard)
    im256 = src_im.resize((256, 256), Image.Resampling.LANCZOS)
    png_buf = io.BytesIO()
    im256.save(png_buf, format='PNG')
    entries.append((0, 0, png_buf.getvalue()))
    
    num_images = len(entries)
    offset = 6 + (16 * num_images)
    
    ico_bytes = bytearray()
    ico_bytes.extend(struct.pack('<HHH', 0, 1, num_images))
    
    for w, h, data in entries:
        b_w = 0 if w >= 256 else w
        b_h = 0 if h >= 256 else h
        ico_bytes.extend(struct.pack('<BBBBHHII',
            b_w, b_h, 0, 0, 1, 32, len(data), offset
        ))
        offset += len(data)
        
    for w, h, data in entries:
        ico_bytes.extend(data)
        
    with open(ico_path, 'wb') as f:
        f.write(ico_bytes)
    print(f'Generated Windows DIB ICO at {ico_path} ({len(ico_bytes)} bytes, {num_images} resolutions)')

if __name__ == '__main__':
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    png = os.path.join(root, 'assets', 'logos', 'clouddrive.png')
    ico = os.path.join(root, 'assets', 'logos', 'clouddrive.ico')
    generate_ico(png, ico)
