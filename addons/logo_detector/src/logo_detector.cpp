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
    float confidence;
    String text;
};

struct LogoDetector::Impl {
    Ort::Env env;
    std::unique_ptr<Ort::Session> yolo_session;
    std::unique_ptr<Ort::Session> ocr_det_session;
    std::unique_ptr<Ort::Session> ocr_rec_session;

    // Store name strings and expose const char* views for Run().
    std::vector<std::string> yolo_input_name_strings;
    std::vector<std::string> yolo_output_name_strings;
    std::vector<std::string> ocr_det_input_name_strings;
    std::vector<std::string> ocr_det_output_name_strings;
    std::vector<std::string> ocr_rec_input_name_strings;
    std::vector<std::string> ocr_rec_output_name_strings;

    Ort::MemoryInfo memory_info;
    std::vector<std::string> charset;

    bool yolo_loaded = false;
    bool ocr_det_loaded = false;
    bool ocr_rec_loaded = false;
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
    session_options.SetIntraOpNumThreads(1);
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
// YOLO postprocessing
// ---------------------------------------------------------------------------

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

static String recognize_text(
    Ort::Session *p_session,
    Ort::MemoryInfo &p_memory_info,
    const std::vector<std::string> &p_input_names,
    const std::vector<std::string> &p_output_names,
    const std::vector<std::string> &p_charset,
    const Ref<Image> &p_crop
);

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

static std::vector<float> image_to_chw(
    const Ref<Image> &p_image,
    int target_w,
    int target_h,
    float norm_mean[3],
    float norm_std[3]
) {
    Ref<Image> img = p_image->duplicate();
    if (img->get_format() != Image::FORMAT_RGB8) {
        img->convert(Image::FORMAT_RGB8);
    }
    img->resize(target_w, target_h, Image::INTERPOLATE_BILINEAR);

    std::vector<float> data(target_w * target_h * 3);
    const uint8_t *pixels = img->get_data().ptr();

    for (int c = 0; c < 3; c++) {
        for (int h = 0; h < target_h; h++) {
            for (int w = 0; w < target_w; w++) {
                int src_idx = (h * target_w + w) * 3 + c;
                int dst_idx = c * target_h * target_w + h * target_w + w;
                float val = pixels[src_idx] / 255.0f;
                data[dst_idx] = (val - norm_mean[c]) / norm_std[c];
            }
        }
    }

    return data;
}

// ---------------------------------------------------------------------------
// OCR crop recognition
// ---------------------------------------------------------------------------

static String recognize_crop(
    Ort::Session *p_rec_session,
    Ort::MemoryInfo &p_memory_info,
    const std::vector<std::string> &p_input_names,
    const std::vector<std::string> &p_output_names,
    const std::vector<std::string> &p_charset,
    const Ref<Image> &p_image,
    float x1, float y1, float x2, float y2
) {
    Ref<Image> crop = crop_box(p_image, x1, y1, x2, y2);
    return recognize_text(p_rec_session, p_memory_info, p_input_names, p_output_names, p_charset, crop);
}

// ---------------------------------------------------------------------------
// OCR recognition (CRNN with CTC)
// ---------------------------------------------------------------------------

static String ctc_decode(const std::vector<int> &p_indices, const std::vector<std::string> &p_charset) {
    std::string text;
    int prev = -1;
    for (int idx : p_indices) {
        if (idx == 0 || idx == prev) continue; // blank or repeat
        if (idx >= 0 && (size_t)idx < p_charset.size()) {
            text += p_charset[idx];
        }
        prev = idx;
    }
    return String(text.c_str());
}

static String recognize_text(
    Ort::Session *p_session,
    Ort::MemoryInfo &p_memory_info,
    const std::vector<std::string> &p_input_names,
    const std::vector<std::string> &p_output_names,
    const std::vector<std::string> &p_charset,
    const Ref<Image> &p_crop
) {
    if (!p_session || p_input_names.empty() || p_output_names.empty()) return String();

    // Recognition model expects height 48 and a dynamic width
    // that is a multiple of 8 (clamp to a reasonable max).
    const int target_h = 48;
    int src_w = p_crop->get_width();
    int src_h = p_crop->get_height();
    float aspect = (float)src_w / std::max(1, src_h);
    int target_w = (int)(target_h * aspect);
    target_w = std::max(32, (target_w + 7) / 8 * 8);
    target_w = std::min(target_w, 640);

    float rec_mean[3] = {0.5f, 0.5f, 0.5f};
    float rec_std[3] = {0.5f, 0.5f, 0.5f};
    std::vector<float> input_data = image_to_chw(p_crop, target_w, target_h, rec_mean, rec_std);

    const int64_t input_shape[] = {1, 3, target_h, target_w};
    Ort::Value input_tensor = Ort::Value::CreateTensor<float>(
        p_memory_info,
        input_data.data(),
        input_data.size(),
        input_shape,
        4
    );

    std::vector<Ort::Value> output_tensors;
    try {
        std::vector<const char*> input_names = to_cstr_array(p_input_names);
        std::vector<const char*> output_names = to_cstr_array(p_output_names);
        output_tensors = p_session->Run(
            Ort::RunOptions{nullptr},
            input_names.data(),
            &input_tensor,
            1,
            output_names.data(),
            output_names.size()
        );
    } catch (const std::exception &e) {
        UtilityFunctions::print("OCR recognition inference failed: ", e.what());
        return String();
    }

    auto out_shape = output_tensors[0].GetTensorTypeAndShapeInfo().GetShape();
    // RapidOCR CRNN output shape: [batch, seq_len, num_classes] (batch-major).
    int seq_len = (int)out_shape[1];
    int num_classes = (int)out_shape[2];
    const float *logits = output_tensors[0].GetTensorData<float>();

    std::vector<int> indices;
    for (int t = 0; t < seq_len; t++) {
        int best_idx = 0;
        float best_val = -1e30f;
        for (int c = 0; c < num_classes; c++) {
            float val = logits[t * num_classes + c];
            if (val > best_val) {
                best_val = val;
                best_idx = c;
            }
        }
        indices.push_back(best_idx);
    }

    return ctc_decode(indices, p_charset);
}

// ---------------------------------------------------------------------------
// Public OCR methods
// ---------------------------------------------------------------------------

Array LogoDetector::ocr_full_image(const Ref<Image> &p_image) {
    Array result;

    // NOTE: This implementation uses YOLO candidate crops as the text regions
    // and runs CRNN recognition on each crop. It does not run a full DBNet
    // text detector. This is a pragmatic trade-off for the title/logo use case.
    if (!impl->yolo_loaded || !impl->ocr_rec_loaded || !impl->charset_loaded || p_image.is_null()) {
        return result;
    }

    Ref<Image> img = p_image->duplicate();
    if (img->get_format() != Image::FORMAT_RGB8) {
        img->convert(Image::FORMAT_RGB8);
    }

    Array candidates = detect_candidates(p_image, 0.15f, 0.45f, 10);

    for (int i = 0; i < candidates.size(); i++) {
        Dictionary cand = candidates[i];
        String text = recognize_crop(
            impl->ocr_rec_session.get(),
            impl->memory_info,
            impl->ocr_rec_input_name_strings,
            impl->ocr_rec_output_name_strings,
            impl->charset,
            img,
            (float)cand["x1"],
            (float)cand["y1"],
            (float)cand["x2"],
            (float)cand["y2"]
        );

        if (!text.is_empty()) {
            Dictionary dict;
            dict["x1"] = cand["x1"];
            dict["y1"] = cand["y1"];
            dict["x2"] = cand["x2"];
            dict["y2"] = cand["y2"];
            dict["text"] = text;
            dict["confidence"] = cand["confidence"];
            result.append(dict);
        }
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

    if (!impl->yolo_loaded || !impl->ocr_rec_loaded || !impl->charset_loaded || p_image.is_null()) {
        return result;
    }

    Array candidates = detect_candidates(p_image, p_conf_threshold, p_nms_threshold, 5);
    Array ocr_words = ocr_full_image(p_image);

    if (candidates.size() == 0) {
        return result;
    }

    // Score each candidate by its nearest OCR word's similarity to the title.
    // This mirrors the Python v4 token-based approach at a basic level.
    String title_lower = p_title.to_lower();
    float best_score = -1.0f;
    Dictionary best_candidate;

    for (int i = 0; i < candidates.size(); i++) {
        Dictionary cand = candidates[i];
        float cx = ((float)cand["x1"] + (float)cand["x2"]) / 2.0f;
        float cy = ((float)cand["y1"] + (float)cand["y2"]) / 2.0f;

        float best_word_score = 0.0f;
        String matched_text;

        for (int j = 0; j < ocr_words.size(); j++) {
            Dictionary word = ocr_words[j];
            float wcx = ((float)word["x1"] + (float)word["x2"]) / 2.0f;
            float wcy = ((float)word["y1"] + (float)word["y2"]) / 2.0f;
            String text = word["text"];

            float dx = cx - wcx;
            float dy = cy - wcy;
            float dist = std::sqrt(dx * dx + dy * dy);

            String text_lower = text.to_lower();
            float full_sim = 0.0f;
            if (!text_lower.is_empty() && !title_lower.is_empty()) {
                // Simple Levenshtein-like similarity via Godot's built-in
                // String methods is not available, so we use a crude containment check.
                if (title_lower.contains(text_lower) || text_lower.contains(title_lower)) {
                    full_sim = 1.0f;
                }
            }

            float score = full_sim * std::max(0.0f, 1.0f - dist / 300.0f);
            if (score > best_word_score) {
                best_word_score = score;
                matched_text = text;
            }
        }

        float cand_conf = (float)cand["confidence"];
        float combined = cand_conf * 0.3f + best_word_score * 0.7f;

        if (combined > best_score) {
            best_score = combined;
            best_candidate = cand;
            best_candidate["matched_text"] = matched_text;
            best_candidate["title_score"] = best_word_score;
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

    return result;
}

// ---------------------------------------------------------------------------
// GDScript bindings
// ---------------------------------------------------------------------------

void LogoDetector::_bind_methods() {
    ClassDB::bind_method(D_METHOD("load_yolo_model", "model_path"), &LogoDetector::load_yolo_model);
    ClassDB::bind_method(D_METHOD("load_ocr_det_model", "model_path"), &LogoDetector::load_ocr_det_model);
    ClassDB::bind_method(D_METHOD("load_ocr_rec_model", "model_path"), &LogoDetector::load_ocr_rec_model);
    ClassDB::bind_method(D_METHOD("load_ocr_charset", "charset_path"), &LogoDetector::load_ocr_charset);

    ClassDB::bind_method(D_METHOD("is_yolo_model_loaded"), &LogoDetector::is_yolo_model_loaded);
    ClassDB::bind_method(D_METHOD("is_ocr_det_model_loaded"), &LogoDetector::is_ocr_det_model_loaded);
    ClassDB::bind_method(D_METHOD("is_ocr_rec_model_loaded"), &LogoDetector::is_ocr_rec_model_loaded);

    ClassDB::bind_method(D_METHOD("detect_candidates", "image", "conf_threshold", "nms_threshold", "top_k"),
                         &LogoDetector::detect_candidates, DEFVAL(0.15f), DEFVAL(0.45f), DEFVAL(5));
    ClassDB::bind_method(D_METHOD("ocr_full_image", "image"), &LogoDetector::ocr_full_image);
    ClassDB::bind_method(D_METHOD("detect_title_box", "image", "title", "conf_threshold", "nms_threshold"),
                         &LogoDetector::detect_title_box, DEFVAL(0.15f), DEFVAL(0.45f));
}

} // namespace godot
