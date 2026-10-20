"""Minimal, documented patch of the pinned msplat-ios CLI (control harness only; engine code untouched):
 1) --eval splits train/test by image-name prefix ('t_' = test) instead of every-Nth, so held-out and rotation-path views are never trained on;
 2) every evaluated view's render is written to $MSPLAT_RENDER_DIR/<image name> with the engine's own renderer."""
import sys
p = sys.argv[1] + '/cli/msplat.cpp'; s = open(p, encoding='utf-8').read()
a = "auto [train, test] = inputData.splitTrainTestIndices(testEvery);"
assert a in s
s = s.replace(a, """std::vector<size_t> train, test;
            for (size_t ci = 0; ci < inputData.cameras.size(); ci++) {
                std::string fn = fs::path(inputData.cameras[ci].filePath).filename().string();
                if (fn.rfind("t_", 0) == 0) test.push_back(ci); else train.push_back(ci);
            }""")
b = "float p = psnr(rgb_cpu, gt_cpu);"
assert b in s
s = s.replace(b, """if (const char* rd = std::getenv("MSPLAT_RENDER_DIR")) {
                    fs::create_directories(rd);
                    Image outImg; outImg.width = (int)rgb_cpu.size(1); outImg.height = (int)rgb_cpu.size(0);
                    outImg.data.resize(outImg.width * outImg.height * 3);
                    memcpy(outImg.ptr(), rgb_cpu.data_ptr(), outImg.data.size() * sizeof(float));
                    // msplat's imwriteRGB() makes a 3-byte/pixel CGBitmapContext, which CoreGraphics rejects (null context, no file, no error): write raw float32 RGB instead
                    FILE* fp = fopen((fs::path(rd) / (fs::path(testCam.filePath).filename().string() + ".f32")).c_str(), "wb");
                    if (fp) { fwrite(outImg.data.data(), sizeof(float), outImg.data.size(), fp); fclose(fp); }
                }
                """ + b)
open(p, 'w', encoding='utf-8').write(s); print('patched', p)
