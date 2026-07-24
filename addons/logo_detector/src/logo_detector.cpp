#include "logo_detector.hpp"

#include <onnxruntime_cxx_api.h>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <vector>
#include <memory>
#include <cmath>
#include <algorithm>
#include <string>
#include <fstream>
#include <sstream>
#include <map>
#include <unordered_map>
#include <utility>

#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#endif

namespace godot {

// ---------------------------------------------------------------------------
// Internal structures
// ---------------------------------------------------------------------------

struct Candidate {
    float x1, y1, x2, y2;
    float confidence;
};

struct OcrWord {
    float x1, y1, x2, y2;
    float confidence;  // DBNet box score
    float text_score;  // mean CRNN softmax probability for the decoded text
    String text;
};

struct LogoDetector::Impl {
    Ort::Env env;
    std::unique_ptr<Ort::Session> yolo_session;
    std::unique_ptr<Ort::Session> ocr_det_session;
    std::unique_ptr<Ort::Session> ocr_rec_session;
    std::unique_ptr<Ort::Session> ocr_cls_session;

    // Store name strings and expose const char* views for Run().
    std::vector<std::string> yolo_input_name_strings;
    std::vector<std::string> yolo_output_name_strings;
    std::vector<std::string> ocr_det_input_name_strings;
    std::vector<std::string> ocr_det_output_name_strings;
    std::vector<std::string> ocr_rec_input_name_strings;
    std::vector<std::string> ocr_rec_output_name_strings;
    std::vector<std::string> ocr_cls_input_name_strings;
    std::vector<std::string> ocr_cls_output_name_strings;

    Ort::MemoryInfo memory_info;
    std::vector<std::string> charset;

    bool yolo_loaded = false;
    bool ocr_det_loaded = false;
    bool ocr_rec_loaded = false;
    bool ocr_cls_loaded = false;
    bool charset_loaded = false;

    Impl() : env(ORT_LOGGING_LEVEL_WARNING, "LogoDetector"),
             memory_info(Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault)) {}
};

// ---------------------------------------------------------------------------
// Platform helpers
// ---------------------------------------------------------------------------

#ifdef _WIN32
using ort_path_string = std::wstring;
static ort_path_string to_ort_path(const std::string &p_path) {
    int len = MultiByteToWideChar(CP_UTF8, 0, p_path.c_str(), -1, nullptr, 0);
    ort_path_string result(len - 1, 0);
    MultiByteToWideChar(CP_UTF8, 0, p_path.c_str(), -1, &result[0], len);
    return result;
}
#else
using ort_path_string = std::string;
static ort_path_string to_ort_path(const std::string &p_path) { return p_path; }
#endif

static std::vector<const char*> to_cstr_array(const std::vector<std::string> &p_strings) {
    std::vector<const char*> result;
    result.reserve(p_strings.size());
    for (const auto &s : p_strings) {
        result.push_back(s.c_str());
    }
    return result;
}

// ---------------------------------------------------------------------------
// Loading / session setup
// ---------------------------------------------------------------------------

static int g_logo_detector_intra_op_threads = 1;

static Error load_onnx_session(
    const String &p_model_path,
    Ort::Env &p_env,
    std::unique_ptr<Ort::Session> &r_session,
    std::vector<std::string> &r_input_names,
    std::vector<std::string> &r_output_names
) {
    if (p_model_path.is_empty()) {
        return ERR_FILE_NOT_FOUND;
    }

    // ONNX Runtime expects a native filesystem path, not a Godot res:// URL.
    String global_path = ProjectSettings::get_singleton()->globalize_path(p_model_path);
    if (global_path.is_empty()) {
        UtilityFunctions::print("Failed to globalize model path: ", p_model_path);
        return ERR_FILE_NOT_FOUND;
    }

    std::string model_path = global_path.utf8().get_data();
    ort_path_string ort_path = to_ort_path(model_path);

    Ort::SessionOptions session_options;
    session_options.SetIntraOpNumThreads(g_logo_detector_intra_op_threads);
    session_options.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);

    try {
        r_session = std::make_unique<Ort::Session>(p_env, ort_path.c_str(), session_options);
    } catch (const std::exception &e) {
        UtilityFunctions::print("Failed to load ONNX model: ", e.what());
        return ERR_FILE_CANT_OPEN;
    }

    r_input_names.clear();
    r_output_names.clear();

    Ort::AllocatorWithDefaultOptions allocator;

    size_t num_inputs = r_session->GetInputCount();
    for (size_t i = 0; i < num_inputs; i++) {
        r_input_names.push_back(r_session->GetInputNameAllocated(i, allocator).get());
    }

    size_t num_outputs = r_session->GetOutputCount();
    for (size_t i = 0; i < num_outputs; i++) {
        r_output_names.push_back(r_session->GetOutputNameAllocated(i, allocator).get());
    }

    return OK;
}

LogoDetector::LogoDetector() {
    impl = new Impl();
}

LogoDetector::~LogoDetector() {
    delete impl;
}

void LogoDetector::set_intra_op_num_threads(int p_threads) {
    g_logo_detector_intra_op_threads = std::max(1, p_threads);
}

Error LogoDetector::load_yolo_model(const String &p_model_path) {
    Error err = load_onnx_session(p_model_path, impl->env, impl->yolo_session,
                                  impl->yolo_input_name_strings, impl->yolo_output_name_strings);
    impl->yolo_loaded = (err == OK);
    return err;
}

Error LogoDetector::load_ocr_det_model(const String &p_model_path) {
    Error err = load_onnx_session(p_model_path, impl->env, impl->ocr_det_session,
                                  impl->ocr_det_input_name_strings, impl->ocr_det_output_name_strings);
    impl->ocr_det_loaded = (err == OK);
    return err;
}

static Error extract_charset_from_model(
    Ort::Session *p_session,
    std::vector<std::string> &r_charset
) {
    if (!p_session) {
        return ERR_CANT_OPEN;
    }

    try {
        Ort::ModelMetadata metadata = p_session->GetModelMetadata();
        Ort::AllocatorWithDefaultOptions allocator;
        auto value = metadata.LookupCustomMetadataMapAllocated("character", allocator);
        if (!value) {
            return ERR_DOES_NOT_EXIST;
        }

        std::string character_str(value.get());
        std::istringstream iss(character_str);
        std::string line;
        r_charset.clear();
        while (std::getline(iss, line)) {
            if (!line.empty()) {
                r_charset.push_back(line);
            }
        }
    } catch (const std::exception &e) {
        UtilityFunctions::print("Failed to extract charset from OCR rec model: ", e.what());
        return ERR_CANT_OPEN;
    }

    return r_charset.empty() ? ERR_CANT_OPEN : OK;
}

Error LogoDetector::load_ocr_rec_model(const String &p_model_path) {
    Error err = load_onnx_session(p_model_path, impl->env, impl->ocr_rec_session,
                                  impl->ocr_rec_input_name_strings, impl->ocr_rec_output_name_strings);
    impl->ocr_rec_loaded = (err == OK);

    if (err == OK) {
        Error charset_err = extract_charset_from_model(impl->ocr_rec_session.get(), impl->charset);
        impl->charset_loaded = (charset_err == OK);
        if (!impl->charset_loaded) {
            UtilityFunctions::print("Warning: OCR rec model loaded but charset not found in metadata. Use load_ocr_charset() to provide one.");
        }
    }

    return err;
}

Error LogoDetector::load_ocr_cls_model(const String &p_model_path) {
    Error err = load_onnx_session(p_model_path, impl->env, impl->ocr_cls_session,
                                  impl->ocr_cls_input_name_strings, impl->ocr_cls_output_name_strings);
    impl->ocr_cls_loaded = (err == OK);
    return err;
}

Error LogoDetector::load_ocr_charset(const String &p_charset_path) {
    String global_path = ProjectSettings::get_singleton()->globalize_path(p_charset_path);
    std::string path = global_path.utf8().get_data();
    std::ifstream file(path);
    if (!file.is_open()) {
        return ERR_FILE_CANT_OPEN;
    }

    impl->charset.clear();
    std::string line;
    while (std::getline(file, line)) {
        if (!line.empty()) {
            impl->charset.push_back(line);
        }
    }

    impl->charset_loaded = !impl->charset.empty();
    return impl->charset_loaded ? OK : ERR_FILE_CANT_READ;
}

bool LogoDetector::is_yolo_model_loaded() const { return impl->yolo_loaded; }
bool LogoDetector::is_ocr_det_model_loaded() const { return impl->ocr_det_loaded; }
bool LogoDetector::is_ocr_rec_model_loaded() const { return impl->ocr_rec_loaded; }
bool LogoDetector::is_ocr_cls_model_loaded() const { return impl->ocr_cls_loaded; }

// ---------------------------------------------------------------------------
// YOLO preprocessing
// ---------------------------------------------------------------------------

static void preprocess_yolo(
    const Ref<Image> &p_image,
    std::vector<float> &r_data,
    int &r_src_w,
    int &r_src_h,
    float &r_scale
) {
    Ref<Image> img = p_image->duplicate();
    if (img->get_format() != Image::FORMAT_RGB8) {
        img->convert(Image::FORMAT_RGB8);
    }

    r_src_w = img->get_width();
    r_src_h = img->get_height();

    const int TARGET_SIZE = 640;
    r_scale = std::min(float(TARGET_SIZE) / r_src_w, float(TARGET_SIZE) / r_src_h);
    int new_w = int(r_src_w * r_scale);
    int new_h = int(r_src_h * r_scale);

    img->resize(new_w, new_h, Image::INTERPOLATE_LANCZOS);

    Ref<Image> padded = Image::create(TARGET_SIZE, TARGET_SIZE, false, Image::FORMAT_RGB8);
    padded->fill(Color(114.0f / 255.0f, 114.0f / 255.0f, 114.0f / 255.0f));
    padded->blit_rect(img, Rect2(0, 0, new_w, new_h), Vector2(0, 0));

    r_data.resize(TARGET_SIZE * TARGET_SIZE * 3);
    const uint8_t *pixels = padded->get_data().ptr();

    for (int c = 0; c < 3; c++) {
        for (int h = 0; h < TARGET_SIZE; h++) {
            for (int w = 0; w < TARGET_SIZE; w++) {
                int src_idx = (h * TARGET_SIZE + w) * 3 + c;
                int dst_idx = c * TARGET_SIZE * TARGET_SIZE + h * TARGET_SIZE + w;
				r_data[dst_idx] = pixels[src_idx] / 255.0f;
			}
		}
	}
}

// ---------------------------------------------------------------------------
// Text similarity helpers (mirrors the Python pipeline)
// ---------------------------------------------------------------------------

static int levenshtein_distance(const String &p_a, const String &p_b) {
	int len_a = p_a.length();
	int len_b = p_b.length();
	if (len_a == 0) return len_b;
	if (len_b == 0) return len_a;

	std::vector<int> prev(len_b + 1);
	std::vector<int> curr(len_b + 1);
	for (int j = 0; j <= len_b; j++) {
		prev[j] = j;
	}

	for (int i = 1; i <= len_a; i++) {
		curr[0] = i;
		char32_t ca = p_a[i - 1];
		for (int j = 1; j <= len_b; j++) {
			int cost = (ca == p_b[j - 1]) ? 0 : 1;
			curr[j] = std::min({ prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost });
		}
		std::swap(prev, curr);
	}
	return prev[len_b];
}

static float string_similarity(const String &p_a, const String &p_b) {
	String a = p_a.to_lower().strip_edges();
	String b = p_b.to_lower().strip_edges();
	if (a.is_empty() || b.is_empty()) return 0.0f;
	int max_len = std::max(a.length(), b.length());
	if (max_len == 0) return 1.0f;
	int dist = levenshtein_distance(a, b);
	return 1.0f - (float)dist / (float)max_len;
}

static std::vector<String> extract_alpha_numeric_tokens(const String &p_text) {
	std::vector<String> tokens;
	String current;
	for (int i = 0; i < p_text.length(); i++) {
		char32_t ch = p_text[i];
		bool is_alnum = (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9');
		if (is_alnum) {
			current += String::chr(ch);
		} else if (!current.is_empty()) {
			if (current.length() > 2) {
				tokens.push_back(current);
			}
			current = "";
		}
	}
	if (!current.is_empty() && current.length() > 2) {
		tokens.push_back(current);
	}
	return tokens;
}

static float token_similarity_score(const String &p_ocr_text, const String &p_title) {
	String ocr = p_ocr_text.to_lower().strip_edges();
	String title = p_title.to_lower().strip_edges();
	if (ocr.is_empty() || title.is_empty()) return 0.0f;

	float full_sim = string_similarity(ocr, title);
	std::vector<String> title_tokens = extract_alpha_numeric_tokens(title);
	if (title_tokens.empty()) return full_sim;

	float best_token_sim = 0.0f;
	for (const String &token : title_tokens) {
		float sim = string_similarity(ocr, token);
		if (sim > best_token_sim) best_token_sim = sim;
	}
	return std::max(full_sim, best_token_sim * 0.95f);
}

// ---------------------------------------------------------------------------
// DBNet text detection (full-image OCR text boxes)
// ---------------------------------------------------------------------------

struct Pt {
    int x, y;
    bool operator==(const Pt &p_other) const { return x == p_other.x && y == p_other.y; }
};

static const int8_t NB_DX[8] = {0, 1, 1, 1, 0, -1, -1, -1};
static const int8_t NB_DY[8] = {-1, -1, 0, 1, 1, 1, 0, -1};

static int neighbor_index(int p_dx, int p_dy) {
    for (int i = 0; i < 8; i++) {
        if (NB_DX[i] == p_dx && NB_DY[i] == p_dy) return i;
    }
    return 0;
}

// Moore-neighbor tracing: returns the outer boundary of every foreground blob
// in the binary mask. Blobs are 8-connected and boundaries are ordered clockwise.
static std::vector<std::vector<Pt>> find_outer_contours(
    const std::vector<uint8_t> &p_mask,
    int p_w,
    int p_h
) {
    std::vector<std::vector<Pt>> contours;
    std::vector<uint8_t> visited((size_t)p_w * p_h, 0);

    for (int y = 0; y < p_h; y++) {
        for (int x = 0; x < p_w; x++) {
            int idx = y * p_w + x;
            if (!p_mask[idx]) continue;
            if (visited[idx]) continue;
            // Only start a contour at the leftmost pixel of a blob.
            if (x > 0 && p_mask[idx - 1]) continue;

            std::vector<Pt> contour;
            Pt start{x, y};
            Pt cur = start;
            Pt back{x - 1, y}; // background pixel to the west
            int steps = 0;
            const int MAX_STEPS = (p_w + p_h) * 4;

            do {
                visited[cur.y * p_w + cur.x] = 1;
                contour.push_back(cur);

                int bi = neighbor_index(back.x - cur.x, back.y - cur.y);
                Pt next{-1, -1};
                int ni = -1;
                for (int k = 1; k <= 8; k++) {
                    int i = (bi + k) & 7;
                    int nx = cur.x + NB_DX[i];
                    int ny = cur.y + NB_DY[i];
                    if (nx < 0 || nx >= p_w || ny < 0 || ny >= p_h) continue;
                    if (!p_mask[ny * p_w + nx]) continue;
                    next = {nx, ny};
                    ni = i;
                    break;
                }

                if (next.x == -1) break; // isolated pixel/line
                if (next == start) break;

                // The background pixel that precedes the chosen neighbor in
                // clockwise order becomes the new backtrack point.
                int prev_i = (ni + 7) & 7;
                back = {cur.x + NB_DX[prev_i], cur.y + NB_DY[prev_i]};
                cur = next;
            } while (cur != start && ++steps < MAX_STEPS);

            if (contour.size() >= 4) {
                contours.push_back(std::move(contour));
            }
        }
    }

    return contours;
}

static Ref<Image> crop_box(const Ref<Image> &p_image, float x1, float y1, float x2, float y2);
static Ref<Image> rotate_180(const Ref<Image> &p_image);

static std::vector<bool> classify_rotations_180(
    LogoDetector::Impl *p_impl,
    const std::vector<Ref<Image>> &p_crops
);

static std::vector<std::pair<String, float>> recognize_texts_batch(
    LogoDetector::Impl *p_impl,
    const std::vector<Ref<Image>> &p_crops
);

static bool classify_rotation_180(
    LogoDetector::Impl *p_impl,
    const Ref<Image> &p_crop
) {
    auto results = classify_rotations_180(p_impl, {p_crop});
    return !results.empty() && results[0];
}

static std::pair<String, float> recognize_text(
    LogoDetector::Impl *p_impl,
    const Ref<Image> &p_crop
) {
    auto results = recognize_texts_batch(p_impl, {p_crop});
    return results.empty() ? std::make_pair(String(), 0.0f) : results[0];
}

static float mean_box_score(
    const float *p_pred,
    int p_w,
    int p_h,
    int p_min_x,
    int p_min_y,
    int p_max_x,
    int p_max_y
) {
    double sum = 0.0;
    int count = 0;
    p_min_x = std::max(0, p_min_x);
    p_min_y = std::max(0, p_min_y);
    p_max_x = std::min(p_w - 1, p_max_x);
    p_max_y = std::min(p_h - 1, p_max_y);
    for (int y = p_min_y; y <= p_max_y; y++) {
        for (int x = p_min_x; x <= p_max_x; x++) {
            sum += p_pred[y * p_w + x];
            count++;
        }
    }
    return count > 0 ? (float)(sum / count) : 0.0f;
}

static std::vector<OcrWord> detect_text_words(
    LogoDetector::Impl *p_impl,
    const Ref<Image> &p_image,
    const std::vector<std::string> &p_charset
) {
    std::vector<OcrWord> result;
    if (!p_impl->ocr_det_loaded || !p_impl->ocr_rec_loaded || !p_impl->charset_loaded || p_image.is_null()) {
        return result;
    }

    Ref<Image> img = p_image->duplicate();
    if (img->get_format() != Image::FORMAT_RGB8) {
        img->convert(Image::FORMAT_RGB8);
    }

    int src_w = img->get_width();
    int src_h = img->get_height();
    if (src_w <= 0 || src_h <= 0) return result;

    // PP-OCRv4 det preprocessing: keep min side >= 736, round to multiple of 32.
    const int LIMIT_SIDE_LEN = 736;
    float ratio = 1.0f;
    int min_side = std::min(src_w, src_h);
    if (min_side < LIMIT_SIDE_LEN) {
        ratio = (float)LIMIT_SIDE_LEN / (float)min_side;
    }
    int resize_w = (int)std::round((float)src_w * ratio / 32.0f) * 32;
    int resize_h = (int)std::round((float)src_h * ratio / 32.0f) * 32;
    if (resize_w <= 0 || resize_h <= 0) return result;

    img->resize(resize_w, resize_h, Image::INTERPOLATE_BILINEAR);

    std::vector<float> input_data((size_t)resize_w * resize_h * 3);
    const float MEAN[3] = {0.5f, 0.5f, 0.5f};
    const float STD[3] = {0.5f, 0.5f, 0.5f};
    const uint8_t *pixels = img->get_data().ptr();

    for (int c = 0; c < 3; c++) {
        for (int y = 0; y < resize_h; y++) {
            for (int x = 0; x < resize_w; x++) {
                int src_idx = (y * resize_w + x) * 3 + c;
                int dst_idx = c * resize_h * resize_w + y * resize_w + x;
                input_data[dst_idx] = (pixels[src_idx] / 255.0f - MEAN[c]) / STD[c];
            }
        }
    }

    const int64_t input_shape[] = {1, 3, resize_h, resize_w};
    Ort::Value input_tensor = Ort::Value::CreateTensor<float>(
        p_impl->memory_info,
        input_data.data(),
        input_data.size(),
        input_shape,
        4
    );

    std::vector<Ort::Value> output_tensors;
    try {
        std::vector<const char*> input_names = to_cstr_array(p_impl->ocr_det_input_name_strings);
        std::vector<const char*> output_names = to_cstr_array(p_impl->ocr_det_output_name_strings);
        output_tensors = p_impl->ocr_det_session->Run(
            Ort::RunOptions{nullptr},
            input_names.data(),
            &input_tensor,
            1,
            output_names.data(),
            output_names.size()
        );
    } catch (const std::exception &e) {
        UtilityFunctions::print("OCR detection inference failed: ", e.what());
        return result;
    }

    auto out_shape = output_tensors[0].GetTensorTypeAndShapeInfo().GetShape();
    if (out_shape.size() < 4) return result;
    int out_h = (int)out_shape[2];
    int out_w = (int)out_shape[3];
    const float *pred = output_tensors[0].GetTensorData<float>();

    const float THRESH = 0.3f;
    const float BOX_THRESH = 0.5f;
    const float TEXT_SCORE_THRESH = 0.5f;
    const float UNCLIP_RATIO = 1.6f;
    const int MIN_HEIGHT = 30;
    const float MAX_ASPECT_RATIO = 8.0f;
    const int MAX_CANDIDATES = 200;

    std::vector<uint8_t> mask((size_t)out_w * out_h, 0);
    for (int i = 0; i < out_w * out_h; i++) {
        if (pred[i] > THRESH) mask[i] = 1;
    }

    // Dilate with a 2x2 kernel to match Python use_dilation=true.
    std::vector<uint8_t> dilated = mask;
    for (int y = 0; y < out_h; y++) {
        for (int x = 0; x < out_w; x++) {
            if (mask[y * out_w + x]) continue;
            bool set = false;
            for (int dy = 0; dy <= 1 && y + dy < out_h; dy++) {
                for (int dx = 0; dx <= 1 && x + dx < out_w; dx++) {
                    if (dx == 0 && dy == 0) continue;
                    if (mask[(y + dy) * out_w + (x + dx)]) {
                        set = true;
                        break;
                    }
                }
                if (set) break;
            }
            if (set) dilated[y * out_w + x] = 1;
        }
    }

    std::vector<std::vector<Pt>> contours = find_outer_contours(dilated, out_w, out_h);

    float scale_x = (float)src_w / (float)out_w;
    float scale_y = (float)src_h / (float)out_h;

    struct ScoredBox {
        float x1, y1, x2, y2;
        float box_score;
    };
    std::vector<ScoredBox> candidate_boxes;

    for (const std::vector<Pt> &contour : contours) {
        if (contour.empty()) continue;
        int min_x = out_w, min_y = out_h, max_x = 0, max_y = 0;
        for (const Pt &pt : contour) {
            min_x = std::min(min_x, pt.x);
            min_y = std::min(min_y, pt.y);
            max_x = std::max(max_x, pt.x);
            max_y = std::max(max_y, pt.y);
        }

        float x1 = (float)min_x * scale_x;
        float y1 = (float)min_y * scale_y;
        float x2 = (float)(max_x + 1) * scale_x;
        float y2 = (float)(max_y + 1) * scale_y;

        float bw = x2 - x1;
        float bh = y2 - y1;
        if (bh < MIN_HEIGHT) continue;
        if (bw / std::max(1.0f, bh) > MAX_ASPECT_RATIO) continue;

        float box_score = mean_box_score(pred, out_w, out_h, min_x, min_y, max_x, max_y);
        if (box_score < BOX_THRESH) continue;

        candidate_boxes.push_back({x1, y1, x2, y2, box_score});
    }

    std::sort(candidate_boxes.begin(), candidate_boxes.end(), [](const ScoredBox &a, const ScoredBox &b) {
        return a.box_score > b.box_score;
    });

    const int REC_BATCH_SIZE = 32;

    int count = std::min((int)candidate_boxes.size(), MAX_CANDIDATES);

    // Prepare all crops and run CRNN in batches instead of one crop at a time.
    for (int batch_start = 0; batch_start < count; batch_start += REC_BATCH_SIZE) {
        int batch_end = std::min(batch_start + REC_BATCH_SIZE, count);
        std::vector<Ref<Image>> crops;
        crops.reserve(batch_end - batch_start);

        for (int i = batch_start; i < batch_end; i++) {
            const ScoredBox &box = candidate_boxes[i];

            // Unclip/padding to give the recognizer a bit of margin.
            float cx = (box.x1 + box.x2) * 0.5f;
            float cy = (box.y1 + box.y2) * 0.5f;
            float half_w = (box.x2 - box.x1) * 0.5f * UNCLIP_RATIO;
            float half_h = (box.y2 - box.y1) * 0.5f * UNCLIP_RATIO;
            float x1 = std::max(0.0f, cx - half_w);
            float y1 = std::max(0.0f, cy - half_h);
            float x2 = std::min((float)src_w, cx + half_w);
            float y2 = std::min((float)src_h, cy + half_h);

            crops.push_back(crop_box(p_image, x1, y1, x2, y2));
        }

        std::vector<std::pair<String, float>> rec_results = recognize_texts_batch(p_impl, crops);

        for (int i = batch_start; i < batch_end; i++) {
            const ScoredBox &box = candidate_boxes[i];
            const auto &rec = rec_results[i - batch_start];
            const String &text = rec.first;
            float text_score = rec.second;

            if (!text.is_empty() && text_score >= TEXT_SCORE_THRESH) {
                // Unclip/padding to give the recognizer a bit of margin.
                float cx = (box.x1 + box.x2) * 0.5f;
                float cy = (box.y1 + box.y2) * 0.5f;
                float half_w = (box.x2 - box.x1) * 0.5f * UNCLIP_RATIO;
                float half_h = (box.y2 - box.y1) * 0.5f * UNCLIP_RATIO;
                float x1 = std::max(0.0f, cx - half_w);
                float y1 = std::max(0.0f, cy - half_h);
                float x2 = std::min((float)src_w, cx + half_w);
                float y2 = std::min((float)src_h, cy + half_h);

                OcrWord word;
                word.x1 = x1;
                word.y1 = y1;
                word.x2 = x2;
                word.y2 = y2;
                word.confidence = box.box_score;
                word.text_score = text_score;
                word.text = text;
                result.push_back(word);
            }
        }
    }

    return result;
}




static inline float compute_iou(const Candidate &a, const Candidate &b) {
    float x1 = std::max(a.x1, b.x1);
    float y1 = std::max(a.y1, b.y1);
    float x2 = std::min(a.x2, b.x2);
    float y2 = std::min(a.y2, b.y2);

    float inter_w = std::max(0.0f, x2 - x1);
    float inter_h = std::max(0.0f, y2 - y1);
    float inter_area = inter_w * inter_h;

    float area_a = (a.x2 - a.x1) * (a.y2 - a.y1);
    float area_b = (b.x2 - b.x1) * (b.y2 - b.y1);

    float union_area = area_a + area_b - inter_area;
    if (union_area <= 0.0f) return 0.0f;
    return inter_area / union_area;
}

static std::vector<Candidate> nms(
    const std::vector<Candidate> &p_candidates,
    float p_threshold
) {
    std::vector<Candidate> sorted = p_candidates;
    std::sort(sorted.begin(), sorted.end(), [](const Candidate &a, const Candidate &b) {
        return a.confidence > b.confidence;
    });

    std::vector<Candidate> result;
    std::vector<bool> suppressed(sorted.size(), false);

    for (size_t i = 0; i < sorted.size(); i++) {
        if (suppressed[i]) continue;
        result.push_back(sorted[i]);

        for (size_t j = i + 1; j < sorted.size(); j++) {
            if (suppressed[j]) continue;
            if (compute_iou(sorted[i], sorted[j]) > p_threshold) {
                suppressed[j] = true;
            }
        }
    }

    return result;
}

Array LogoDetector::detect_candidates(
    const Ref<Image> &p_image,
    float p_conf_threshold,
    float p_nms_threshold,
    int p_top_k
) {
    Array result;

    if (!impl->yolo_loaded || p_image.is_null()) {
        return result;
    }

    int src_w = 0, src_h = 0;
    float scale = 1.0f;
    std::vector<float> input_data;
    preprocess_yolo(p_image, input_data, src_w, src_h, scale);

    const int TARGET_SIZE = 640;
    const int64_t input_shape[] = {1, 3, TARGET_SIZE, TARGET_SIZE};
    Ort::Value input_tensor = Ort::Value::CreateTensor<float>(
        impl->memory_info,
        input_data.data(),
        input_data.size(),
        input_shape,
        4
    );

    std::vector<Ort::Value> output_tensors;
    try {
        std::vector<const char*> input_names = to_cstr_array(impl->yolo_input_name_strings);
        std::vector<const char*> output_names = to_cstr_array(impl->yolo_output_name_strings);
        output_tensors = impl->yolo_session->Run(
            Ort::RunOptions{nullptr},
            input_names.data(),
            &input_tensor,
            1,
            output_names.data(),
            output_names.size()
        );
    } catch (const std::exception &e) {
        UtilityFunctions::print("YOLO inference failed: ", e.what());
        return result;
    }

    if (output_tensors.size() < 1) {
        return result;
    }

    // YOLOv8-seg output: [1, 4 + nc + nm, 8400] + optional mask prototypes.
    auto boxes_shape = output_tensors[0].GetTensorTypeAndShapeInfo().GetShape();
    int num_channels = (int)boxes_shape[1];
    int num_dets = (int)boxes_shape[2];
    const float *boxes_tensor = output_tensors[0].GetTensorData<float>();

    std::vector<Candidate> candidates;
    for (int i = 0; i < num_dets; i++) {
        // YOLOv8-seg output layout is [1, 4+nc+nm, 8400] (channels-major).
        // In row-major order, the value for channel c and anchor i is at
        // c * num_dets + i.
        float cx = boxes_tensor[0 * num_dets + i];
        float cy = boxes_tensor[1 * num_dets + i];
        float w = boxes_tensor[2 * num_dets + i];
        float h = boxes_tensor[3 * num_dets + i];
        float conf = boxes_tensor[4 * num_dets + i]; // single-class model

        if (conf < p_conf_threshold) continue;

        // YOLOv8 outputs boxes in 640x640 letterbox space (pixels).
        float x1_640 = cx - w / 2.0f;
        float y1_640 = cy - h / 2.0f;
        float x2_640 = cx + w / 2.0f;
        float y2_640 = cy + h / 2.0f;

        // Map back to original image coordinates.
        Candidate cand;
        cand.x1 = std::clamp(x1_640 / scale, 0.0f, (float)src_w);
        cand.y1 = std::clamp(y1_640 / scale, 0.0f, (float)src_h);
        cand.x2 = std::clamp(x2_640 / scale, 0.0f, (float)src_w);
        cand.y2 = std::clamp(y2_640 / scale, 0.0f, (float)src_h);
        cand.confidence = conf;

        candidates.push_back(cand);
    }

    std::vector<Candidate> kept = nms(candidates, p_nms_threshold);

    int count = std::min((int)kept.size(), p_top_k);
    for (int i = 0; i < count; i++) {
        Dictionary dict;
        dict["x1"] = kept[i].x1;
        dict["y1"] = kept[i].y1;
        dict["x2"] = kept[i].x2;
        dict["y2"] = kept[i].y2;
        dict["confidence"] = kept[i].confidence;
        result.append(dict);
    }

    return result;
}

// ---------------------------------------------------------------------------
// OCR helpers
// ---------------------------------------------------------------------------

static Ref<Image> crop_box(const Ref<Image> &p_image, float x1, float y1, float x2, float y2) {
    int src_w = p_image->get_width();
    int src_h = p_image->get_height();

    int ix1 = std::max(0, (int)x1);
    int iy1 = std::max(0, (int)y1);
    int ix2 = std::min(src_w, (int)std::ceil(x2));
    int iy2 = std::min(src_h, (int)std::ceil(y2));

    int crop_w = std::max(1, ix2 - ix1);
    int crop_h = std::max(1, iy2 - iy1);

    Ref<Image> cropped = Image::create(crop_w, crop_h, false, Image::FORMAT_RGB8);
    cropped->blit_rect(p_image, Rect2(ix1, iy1, crop_w, crop_h), Vector2(0, 0));
    return cropped;
}

static Ref<Image> rotate_180(const Ref<Image> &p_image) {
    if (p_image.is_null()) return Ref<Image>();
    int w = p_image->get_width();
    int h = p_image->get_height();
    Ref<Image> dst = Image::create(w, h, false, p_image->get_format());
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            dst->set_pixel(x, y, p_image->get_pixel(w - 1 - x, h - 1 - y));
        }
    }
    return dst;
}

// ---------------------------------------------------------------------------
// OCR recognition (CRNN with CTC)
// ---------------------------------------------------------------------------

static std::pair<String, float> ctc_decode(
    const std::vector<int> &p_indices,
    const std::vector<float> &p_probs,
    const std::vector<std::string> &p_charset
) {
    std::string text;
    float prob_sum = 0.0f;
    int count = 0;
    int prev = -1;
    for (size_t i = 0; i < p_indices.size(); i++) {
        int idx = p_indices[i];
        if (idx == 0 || idx == prev) continue; // blank or repeat
        if (idx >= 0 && (size_t)idx < p_charset.size()) {
            text += p_charset[idx];
            prob_sum += p_probs[i];
            count++;
        }
        prev = idx;
    }
    float score = count > 0 ? prob_sum / count : 0.0f;
    return {String(text.c_str()), score};
}

static std::vector<bool> classify_rotations_180(
    LogoDetector::Impl *p_impl,
    const std::vector<Ref<Image>> &p_crops
) {
    std::vector<bool> result(p_crops.size(), false);
    if (!p_impl || !p_impl->ocr_cls_loaded || p_crops.empty()) return result;

    const int CLS_W = 192;
    const int CLS_H = 48;
    int n = (int)p_crops.size();
    std::vector<float> input_data((size_t)n * 3 * CLS_H * CLS_W, 0.0f);

    for (int idx = 0; idx < n; idx++) {
        Ref<Image> img = p_crops[idx]->duplicate();
        if (img->get_format() != Image::FORMAT_RGB8) {
            img->convert(Image::FORMAT_RGB8);
        }
        img->resize(CLS_W, CLS_H, Image::INTERPOLATE_BILINEAR);
        const uint8_t *pixels = img->get_data().ptr();

        for (int c = 0; c < 3; c++) {
            for (int y = 0; y < CLS_H; y++) {
                for (int x = 0; x < CLS_W; x++) {
                    int src_idx = (y * CLS_W + x) * 3 + c;
                    int dst_idx = ((idx * 3 + c) * CLS_H + y) * CLS_W + x;
                    input_data[dst_idx] = (pixels[src_idx] / 255.0f - 0.5f) / 0.5f;
                }
            }
        }
    }

    const int64_t input_shape[] = {n, 3, CLS_H, CLS_W};
    Ort::Value input_tensor = Ort::Value::CreateTensor<float>(
        p_impl->memory_info,
        input_data.data(),
        input_data.size(),
        input_shape,
        4
    );

    std::vector<Ort::Value> output_tensors;
    try {
        std::vector<const char*> input_names = to_cstr_array(p_impl->ocr_cls_input_name_strings);
        std::vector<const char*> output_names = to_cstr_array(p_impl->ocr_cls_output_name_strings);
        output_tensors = p_impl->ocr_cls_session->Run(
            Ort::RunOptions{nullptr},
            input_names.data(),
            &input_tensor,
            1,
            output_names.data(),
            output_names.size()
        );
    } catch (const std::exception &e) {
        UtilityFunctions::print("OCR classifier batch inference failed: ", e.what());
        return result;
    }

    auto out_shape = output_tensors[0].GetTensorTypeAndShapeInfo().GetShape();
    int rank = (int)out_shape.size();
    if (rank < 2) return result;

    int num_classes = (int)out_shape[rank - 1];
    int inner = 1;
    for (int i = 1; i < rank - 1; i++) inner *= (int)out_shape[i];
    const float *logits = output_tensors[0].GetTensorData<float>();

    for (int idx = 0; idx < n; idx++) {
        int base = idx * inner * num_classes + (inner - 1) * num_classes;
        float max_val = -1e30f;
        for (int c = 0; c < num_classes; c++) {
            max_val = std::max(max_val, logits[base + c]);
        }
        double sum = 0.0;
        for (int c = 0; c < num_classes; c++) {
            sum += std::exp((double)(logits[base + c] - max_val));
        }
        float prob_180 = (float)(std::exp((double)(logits[base + 1] - max_val)) / sum);
        result[idx] = prob_180 > 0.9f;
    }

    return result;
}

static std::vector<std::pair<String, float>> recognize_texts_batch(
    LogoDetector::Impl *p_impl,
    const std::vector<Ref<Image>> &p_crops
) {
    std::vector<std::pair<String, float>> results(p_crops.size(), {String(), 0.0f});
    if (!p_impl || !p_impl->ocr_rec_loaded || p_crops.empty()) return results;

    const int TARGET_H = 48;
    const int FIXED_W = 320;
    int n = (int)p_crops.size();

    // Apply rotation correction if a classifier is available.
    std::vector<Ref<Image>> crops = p_crops;
    if (p_impl->ocr_cls_loaded) {
        std::vector<bool> rotate = classify_rotations_180(p_impl, crops);
        for (int i = 0; i < n; i++) {
            if (rotate[i]) {
                crops[i] = rotate_180(crops[i]);
            }
        }
    }

    std::vector<float> input_data((size_t)n * 3 * TARGET_H * FIXED_W, 0.0f);
    for (int idx = 0; idx < n; idx++) {
        Ref<Image> img = crops[idx]->duplicate();
        if (img->get_format() != Image::FORMAT_RGB8) {
            img->convert(Image::FORMAT_RGB8);
        }
        int src_w = img->get_width();
        int src_h = img->get_height();
        float aspect = (float)src_w / std::max(1, src_h);
        int target_w = (int)std::round((float)TARGET_H * aspect);
        target_w = std::max(32, target_w);
        target_w = (target_w + 7) / 8 * 8;
        target_w = std::min(target_w, FIXED_W);

        img->resize(target_w, TARGET_H, Image::INTERPOLATE_BILINEAR);
        const uint8_t *pixels = img->get_data().ptr();

        for (int c = 0; c < 3; c++) {
            for (int y = 0; y < TARGET_H; y++) {
                for (int x = 0; x < target_w; x++) {
                    int src_idx = (y * target_w + x) * 3 + c;
                    int dst_idx = ((idx * 3 + c) * TARGET_H + y) * FIXED_W + x;
                    input_data[dst_idx] = (pixels[src_idx] / 255.0f - 0.5f) / 0.5f;
                }
            }
        }
    }

    const int64_t input_shape[] = {n, 3, TARGET_H, FIXED_W};
    Ort::Value input_tensor = Ort::Value::CreateTensor<float>(
        p_impl->memory_info,
        input_data.data(),
        input_data.size(),
        input_shape,
        4
    );

    std::vector<Ort::Value> output_tensors;
    try {
        std::vector<const char*> input_names = to_cstr_array(p_impl->ocr_rec_input_name_strings);
        std::vector<const char*> output_names = to_cstr_array(p_impl->ocr_rec_output_name_strings);
        output_tensors = p_impl->ocr_rec_session->Run(
            Ort::RunOptions{nullptr},
            input_names.data(),
            &input_tensor,
            1,
            output_names.data(),
            output_names.size()
        );
    } catch (const std::exception &e) {
        UtilityFunctions::print("OCR recognition batch inference failed: ", e.what());
        return results;
    }

    auto out_shape = output_tensors[0].GetTensorTypeAndShapeInfo().GetShape();
    if (out_shape.size() < 3) return results;
    int seq_len = (int)out_shape[1];
    int num_classes = (int)out_shape[2];
    const float *logits = output_tensors[0].GetTensorData<float>();

    for (int idx = 0; idx < n; idx++) {
        const float *sample_logits = logits + (size_t)idx * seq_len * num_classes;
        std::vector<int> indices;
        std::vector<float> probs;
        indices.reserve(seq_len);
        probs.reserve(seq_len);

        for (int t = 0; t < seq_len; t++) {
            int best_idx = 0;
            float best_val = -1e30f;
            for (int c = 0; c < num_classes; c++) {
                float val = sample_logits[t * num_classes + c];
                if (val > best_val) {
                    best_val = val;
                    best_idx = c;
                }
            }
            indices.push_back(best_idx);

            double sum = 0.0;
            for (int c = 0; c < num_classes; c++) {
                sum += std::exp((double)(sample_logits[t * num_classes + c] - best_val));
            }
            probs.push_back((float)(1.0 / sum));
        }

        results[idx] = ctc_decode(indices, probs, p_impl->charset);
    }

    return results;
}


// ---------------------------------------------------------------------------
// Public OCR methods
// ---------------------------------------------------------------------------

Array LogoDetector::ocr_full_image(const Ref<Image> &p_image) {
	Array result;

	if (!impl->ocr_det_loaded || !impl->ocr_rec_loaded || !impl->charset_loaded || p_image.is_null()) {
		return result;
	}

	std::vector<OcrWord> words = detect_text_words(impl, p_image, impl->charset);
	for (const OcrWord &word : words) {
		Dictionary dict;
		dict["x1"] = word.x1;
		dict["y1"] = word.y1;
		dict["x2"] = word.x2;
		dict["y2"] = word.y2;
		dict["text"] = word.text;
		dict["confidence"] = word.confidence;
		dict["text_score"] = word.text_score;
		result.append(dict);
	}

	return result;
}

Dictionary LogoDetector::detect_title_box(
	const Ref<Image> &p_image,
	const String &p_title,
	float p_conf_threshold,
	float p_nms_threshold
) {
	Dictionary result;
	result["detected"] = false;

	if (!impl->yolo_loaded || !impl->ocr_det_loaded || !impl->ocr_rec_loaded || !impl->charset_loaded || p_image.is_null()) {
		return result;
	}

	Array candidates = detect_candidates(p_image, p_conf_threshold, p_nms_threshold, 5);

	// Region-first: if a high-confidence YOLO crop contains a title word, use it immediately.
	const float REGION_MATCH_THRESHOLD = 0.7f;
	for (int i = 0; i < candidates.size(); i++) {
		Dictionary cand = candidates[i];
		float cx1 = (float)cand["x1"];
		float cy1 = (float)cand["y1"];
		float cx2 = (float)cand["x2"];
		float cy2 = (float)cand["y2"];

		Ref<Image> crop = crop_box(p_image, cx1, cy1, cx2, cy2);
		std::vector<OcrWord> crop_words = detect_text_words(impl, crop, impl->charset);
		for (const OcrWord &word : crop_words) {
			float title_score = token_similarity_score(word.text, p_title);
			if (title_score >= REGION_MATCH_THRESHOLD) {
				Dictionary match = cand;
				match["detected"] = true;
				match["matched_text"] = word.text;
				match["title_score"] = title_score;
				match["combined_score"] = (float)cand["confidence"] * 0.3f + title_score * 0.7f;
				return match;
			}
		}
	}

	// Fallback: run OCR on the full image and score all YOLO candidates.
	std::vector<OcrWord> words = detect_text_words(impl, p_image, impl->charset);

	int img_w = p_image->get_width();
	int img_h = p_image->get_height();
	float diag = std::sqrt((float)img_w * (float)img_w + (float)img_h * (float)img_h);

	float best_score = -1.0f;
	Dictionary best_candidate;

	for (int i = 0; i < candidates.size(); i++) {
		Dictionary cand = candidates[i];
		float cx = ((float)cand["x1"] + (float)cand["x2"]) / 2.0f;
		float cy = ((float)cand["y1"] + (float)cand["y2"]) / 2.0f;

		float best_word_score = 0.0f;
		String matched_text;

		for (const OcrWord &word : words) {
			float sim = token_similarity_score(word.text, p_title);
			if (sim < 0.05f) continue;

			float wcx = (word.x1 + word.x2) / 2.0f;
			float wcy = (word.y1 + word.y2) / 2.0f;
			float dx = cx - wcx;
			float dy = cy - wcy;
			float dist = std::sqrt(dx * dx + dy * dy);

			float proximity = std::max(0.0f, 1.0f - dist / (diag * 0.3f));
			float score = sim * proximity;
			if (score > best_word_score) {
				best_word_score = score;
				matched_text = word.text;
			}
		}

		float cand_conf = (float)cand["confidence"];
		float combined = cand_conf * 0.3f + best_word_score * 0.7f;

		if (combined > best_score) {
			best_score = combined;
			best_candidate = cand;
			best_candidate["matched_text"] = matched_text;
			best_candidate["title_score"] = token_similarity_score(matched_text, p_title);
			best_candidate["combined_score"] = combined;
		}
	}

	if (best_score > 0.0f) {
		best_candidate["detected"] = true;
		return best_candidate;
	}

	// Fallback: top YOLO candidate.
	if (candidates.size() > 0) {
		best_candidate = candidates[0];
		best_candidate["detected"] = true;
		best_candidate["matched_text"] = "";
		best_candidate["title_score"] = 0.0f;
		best_candidate["combined_score"] = (float)best_candidate["confidence"];
		return best_candidate;
	}

	// No YOLO candidates: fall back to the best OCR word box if any matches the title.
	if (!words.empty()) {
		float best_sim = 0.0f;
		const OcrWord *best_word = nullptr;
		for (const OcrWord &word : words) {
			float sim = token_similarity_score(word.text, p_title);
			if (sim > best_sim) {
				best_sim = sim;
				best_word = &word;
			}
		}
		if (best_word != nullptr && best_sim >= 0.2f) {
			Dictionary fb;
			fb["detected"] = true;
			fb["x1"] = best_word->x1;
			fb["y1"] = best_word->y1;
			fb["x2"] = best_word->x2;
			fb["y2"] = best_word->y2;
			fb["confidence"] = 0.0f;
			fb["matched_text"] = best_word->text;
			fb["title_score"] = best_sim;
			fb["combined_score"] = best_sim;
			return fb;
		}
	}

	return result;
}

// ---------------------------------------------------------------------------
// GDScript bindings
// ---------------------------------------------------------------------------

void LogoDetector::_bind_methods() {
    ClassDB::bind_method(D_METHOD("load_yolo_model", "model_path"), &LogoDetector::load_yolo_model);
    ClassDB::bind_method(D_METHOD("load_ocr_det_model", "model_path"), &LogoDetector::load_ocr_det_model);
    ClassDB::bind_method(D_METHOD("load_ocr_rec_model", "model_path"), &LogoDetector::load_ocr_rec_model);
    ClassDB::bind_method(D_METHOD("load_ocr_cls_model", "model_path"), &LogoDetector::load_ocr_cls_model);
    ClassDB::bind_method(D_METHOD("load_ocr_charset", "charset_path"), &LogoDetector::load_ocr_charset);

    ClassDB::bind_method(D_METHOD("set_intra_op_num_threads", "threads"), &LogoDetector::set_intra_op_num_threads);

    ClassDB::bind_method(D_METHOD("is_yolo_model_loaded"), &LogoDetector::is_yolo_model_loaded);
    ClassDB::bind_method(D_METHOD("is_ocr_det_model_loaded"), &LogoDetector::is_ocr_det_model_loaded);
    ClassDB::bind_method(D_METHOD("is_ocr_rec_model_loaded"), &LogoDetector::is_ocr_rec_model_loaded);
    ClassDB::bind_method(D_METHOD("is_ocr_cls_model_loaded"), &LogoDetector::is_ocr_cls_model_loaded);

    ClassDB::bind_method(D_METHOD("detect_candidates", "image", "conf_threshold", "nms_threshold", "top_k"),
                         &LogoDetector::detect_candidates, DEFVAL(0.15f), DEFVAL(0.45f), DEFVAL(5));
    ClassDB::bind_method(D_METHOD("ocr_full_image", "image"), &LogoDetector::ocr_full_image);
    ClassDB::bind_method(D_METHOD("detect_title_box", "image", "title", "conf_threshold", "nms_threshold"),
                         &LogoDetector::detect_title_box, DEFVAL(0.15f), DEFVAL(0.45f));
}

} // namespace godot
