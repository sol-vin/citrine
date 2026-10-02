#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include "../include/citrine_video.h"
#include "../include/citrine_draw2d.h"

#define CITRINE_MAX_VIDEOS 4

typedef struct {
    uint32_t id;
    bool     active;
    bool     playing;
    bool     loop;
    float    fps;
    float    current_time;
    uint32_t current_frame;
    uint32_t total_frames;
    char     path[128];
} VideoStream;

static VideoStream s_videos[CITRINE_MAX_VIDEOS];
static uint32_t s_next_video_id = 1;

uint32_t Citrine_LoadVideo(const char* path) {
    for (int i = 0; i < CITRINE_MAX_VIDEOS; i++) {
        if (!s_videos[i].active) {
            s_videos[i].id = s_next_video_id++;
            s_videos[i].active = true;
            s_videos[i].playing = false;
            s_videos[i].loop = false;
            s_videos[i].fps = 15.0f; // Default 15 FPS downsampling for PS2 IPU streaming
            s_videos[i].current_time = 0.0f;
            s_videos[i].current_frame = 0;
            s_videos[i].total_frames = 150; // default 10 seconds @ 15fps
            if (path) {
                strncpy(s_videos[i].path, path, sizeof(s_videos[i].path) - 1);
            }
            return s_videos[i].id;
        }
    }
    return 0;
}

bool Citrine_PlayVideo(uint32_t video_id, bool loop) {
    for (int i = 0; i < CITRINE_MAX_VIDEOS; i++) {
        if (s_videos[i].active && s_videos[i].id == video_id) {
            s_videos[i].playing = true;
            s_videos[i].loop = loop;
            s_videos[i].current_time = 0.0f;
            s_videos[i].current_frame = 0;
            return true;
        }
    }
    return false;
}

void Citrine_DrawVideoFrame(uint32_t video_id, float x, float y, float w, float h) {
    for (int i = 0; i < CITRINE_MAX_VIDEOS; i++) {
        if (s_videos[i].active && s_videos[i].id == video_id) {
            if (s_videos[i].playing) {
                // Advance frame timer (at 15 FPS)
                s_videos[i].current_time += 1.0f / 60.0f; // assuming 60Hz tick
                s_videos[i].current_frame = (uint32_t)(s_videos[i].current_time * s_videos[i].fps);
                if (s_videos[i].current_frame >= s_videos[i].total_frames) {
                    if (s_videos[i].loop) {
                        s_videos[i].current_time = 0.0f;
                        s_videos[i].current_frame = 0;
                    } else {
                        s_videos[i].playing = false;
                    }
                }
            }

            // Draw video frame bounding box and playback indicators
            uint32_t border_color = 0xFF333333; // Dark border
            uint32_t bg_color = 0xFF101010;     // Cinema black background
            Citrine_DrawRectangle(x, y, w, h, bg_color);
            Citrine_DrawLine(x, y, x + w, y, border_color);
            Citrine_DrawLine(x, y + h, x + w, y + h, border_color);
            Citrine_DrawLine(x, y, x, y + h, border_color);
            Citrine_DrawLine(x + w, y, x + w, y + h, border_color);

            // Animate scanline / progress bar
            float progress = (float)s_videos[i].current_frame / (float)s_videos[i].total_frames;
            if (progress > 1.0f) progress = 1.0f;
            Citrine_DrawRectangle(x, y + h - 4.0f, w * progress, 4.0f, 0xFF00AAFF);
            return;
        }
    }
}

bool Citrine_VideoFinished(uint32_t video_id) {
    for (int i = 0; i < CITRINE_MAX_VIDEOS; i++) {
        if (s_videos[i].active && s_videos[i].id == video_id) {
            return !s_videos[i].playing && (s_videos[i].current_frame >= s_videos[i].total_frames);
        }
    }
    return true;
}

void Citrine_PauseVideo(uint32_t video_id) {
    for (int i = 0; i < CITRINE_MAX_VIDEOS; i++) {
        if (s_videos[i].active && s_videos[i].id == video_id) {
            s_videos[i].playing = false;
            return;
        }
    }
}

void Citrine_StopVideo(uint32_t video_id) {
    for (int i = 0; i < CITRINE_MAX_VIDEOS; i++) {
        if (s_videos[i].active && s_videos[i].id == video_id) {
            s_videos[i].playing = false;
            s_videos[i].current_time = 0.0f;
            s_videos[i].current_frame = 0;
            return;
        }
    }
}
