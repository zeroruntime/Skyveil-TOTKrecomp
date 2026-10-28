/* Exercise real PCM -> submix -> splitter -> submix -> stereo output, without a device or game data. */
#include "../../runtime/audio_mixer.c"

_Noreturn void runtime_fail(const char *s) { fprintf(stderr, "probe failure: %s\n", s); exit(2); }
void *ipc_guest(uint64_t at, uint64_t n) { (void)n; return (void *)(uintptr_t)at; }
void dm_guest_write_prepare(void *p, size_t n) { (void)p; (void)n; }
int audio_buffer_empty(const AudrenWaveBuffer *b) { return !b->address || !b->size || b->end <= b->start; }
const void *ipc_arg(const IpcRequest *r, uint32_t a, uint32_t n) { (void)r; (void)a; (void)n; runtime_fail("unexpected IPC"); }
void ipc_out(IpcResponse *r, const void *p, uint32_t n) { (void)r; (void)p; (void)n; runtime_fail("unexpected IPC"); }
_Noreturn void ipc_unimplemented(const IpcSession *s, const IpcRequest *r) { (void)s; (void)r; runtime_fail("unexpected IPC"); }
uint32_t runtime_event_new(void) { return 1; }
uint32_t runtime_event_readable(uint32_t h) { return h; }

static void splitter(Mixer *m, int id, int destination_id, int mix, float volume) {
    m->split[id].ndest = 1;
    m->split[id].ids = calloc(1, sizeof(int));
    m->split[id].ids[0] = destination_id;
    m->dest[destination_id].used = 1;
    m->dest[destination_id].dest = mix;
    m->dest[destination_id].vol[0] = volume;
}

static int settle_master_gain(AudioRenderer *r, float target) {
    Mixer *m = r->mixer;
    unsigned limit = (m->master_ramp_frames + (unsigned)m->frame - 1) / (unsigned)m->frame + 2;
    for (unsigned block = 0; block < limit; block++) {
        audio_mixer_render(r, (double)m->frame / r->param.sample_rate);
        if (m->master_ramp_elapsed >= m->master_ramp_frames && fabsf(m->master_gain - target) <= 1e-6f) return 0;
    }
    fprintf(stderr, "master ramp did not settle at %.3f (got %.6f)\n", target, m->master_gain);
    return 1;
}

static int run_case(int scenario, int initial_master, int target_master, float guest_volume) {
    runtime_audio_master_volume_set(initial_master);
    atomic_store(&device_volume, guest_volume);
    int16_t pcm[16];
    for (int k = 0; k < 16; ++k) pcm[k] = (int16_t)((k - 8) * 512);
    AudioRenderer r = {.param = {.sample_rate=48000, .sample_count=16, .mix_buffer_count=8,
        .voice_count=1, .sink_count=1, .submix_count=3, .splitter_count=2, .splitter_destination_count=3},
        .revision=0x3f564552u};
    r.voices = calloc(1, sizeof *r.voices); r.channels = calloc(6, sizeof *r.channels);
    r.effects = calloc(1, sizeof *r.effects); r.mixes = calloc(4, sizeof *r.mixes);
    r.sinks = calloc(1, sizeof *r.sinks);
    for (int i = 0; i < 4; ++i) r.mixes[i] = (AudrenMixIn){.volume=1, .buffer_count=i?1:2,
        .in_use=1, .dest_mix_id=0, .dest_splitter_id=SPLITTER_UNUSED};
    r.mixes[1].mix[0][0] = 1; r.mixes[1].mix[0][1] = .5f;
    r.mixes[2].dest_mix_id = 1; r.mixes[2].mix[0][0] = 1;
    r.mixes[3].dest_mix_id = 2; r.mixes[3].mix[0][0] = 1;
    r.channels[0].mix[0] = 1;
    r.sinks[0] = (AudrenSinkIn){.type=SINK_DEVICE, .in_use=1, .input_count=2, .inputs={0,1}};
    *r.voices = (ServerVoice){.in={.in_use=1, .sample_rate=48000, .sample_format=FMT_PCM16,
        .channel_count=1, .pitch=1, .volume=1, .mix_id=scenario>=2?3:2,
        .splitter_id=SPLITTER_UNUSED}, .state=SV_STARTED, .valid={1}};
    r.voices[0].buffers[0] = (AudrenWaveBuffer){.address=(uintptr_t)pcm, .size=sizeof pcm, .end=16};
    audio_mixer_open(&r);
    Mixer *m = r.mixer;
    float gain = 1;
    if (scenario >= 1) {
        r.mixes[2].dest_mix_id = -1; r.mixes[2].dest_splitter_id = 0;
        splitter(m, 0, 0, 1, 1);
    }
    if (scenario >= 2) {
        r.mixes[3].dest_mix_id = -1; r.mixes[3].dest_splitter_id = 1;
        splitter(m, 1, 1, 2, 1);
    }
    if (scenario == 3) {
        m->split[1].ndest = 2;
        m->split[1].ids = realloc(m->split[1].ids, 2*sizeof(int));
        m->split[1].ids[1] = 2;
        m->dest[2].used = 1; m->dest[2].dest = 1; m->dest[2].vol[0] = .5f;
        gain = 1.5f;
    }
    runtime_audio_master_volume_set(target_master);
    audio_mixer_render(&r, 16.0/48000);
    float output[32];
    if (audio_mixer_read(&r, output, 16) != 16) runtime_fail("no output frames");
    int failed = 0;
    for (int k = 0; k < 16; ++k) for (int c = 0; c < 2; ++c) {
        float master = (float)initial_master / 100.f;
        if (initial_master != target_master) {
            float progress = fminf((float)(k + 1) / (float)m->master_ramp_frames, 1.f);
            master += ((float)target_master - (float)initial_master) / 100.f * progress;
        }
        float want = pcm[k]/32768.f * gain * guest_volume * master * (c?.5f:1.f);
        if (!isfinite(output[k*2+c]) || fabsf(output[k*2+c]-want)>1e-6f) {
            if (!failed) fprintf(stderr, "route %d frame %d channel %d: got %.7f expected %.7f\n", scenario,k,c,output[k*2+c],want);
            failed = 1;
        }
    }
    if (initial_master != target_master) {
        float partial_gain = m->master_gain;
        runtime_audio_master_volume_set(initial_master);
        audio_mixer_render(&r, 16.0/48000);
        float reversed = partial_gain + ((float)initial_master / 100.f - partial_gain) *
            fminf((float)r.param.sample_count / (float)m->master_ramp_frames, 1.f);
        if (fabsf(m->master_gain - reversed) > 1e-6f) {
            fprintf(stderr, "route %d mid-ramp reversal: got %.7f expected %.7f\n", scenario, m->master_gain, reversed);
            failed = 1;
        }
        failed += settle_master_gain(&r, (float)initial_master / 100.f);

        runtime_audio_master_volume_set(target_master);
        failed += settle_master_gain(&r, (float)target_master / 100.f);
        if (target_master == 0) {
            float silent[32];
            audio_mixer_render(&r, 16.0/48000);
            if (audio_mixer_read(&r, silent, 16) != 16) runtime_fail("no settled-mute frames");
            for (int i = 0; i < 32; i++) if (!isfinite(silent[i]) || silent[i] != 0.0f) {
                fprintf(stderr, "route %d settled mute sample %d was %.7f\n", scenario, i, silent[i]);
                failed = 1;
                break;
            }
        }
    }
    if (fabsf(atomic_load(&device_volume) - guest_volume) > 1e-6f) {
        fprintf(stderr, "route %d changed the guest device volume\n", scenario);
        failed = 1;
    }
    audio_mixer_close(&r);
    atomic_store(&device_volume, 1.0f);
    runtime_audio_master_volume_set(100);
    free(r.voices); free(r.channels); free(r.effects); free(r.mixes); free(r.sinks);
    return failed;
}

/* Exercise the production decoder too: the metadata cursor and decoded samples must agree at EOS. Independent PCM
   buffers make an accidental read into the next stream visible, even when the renderer's consumed count looks right. */
static int eos_samples(void) {
    int16_t first[100], second[480];
    for (int i = 0; i < 100; i++) first[i] = 8192;
    for (int i = 0; i < 480; i++) second[i] = -16384;
    AudioRenderer r = {.param = {.sample_rate = 48000}};
    ServerVoice v = {.in = {.sample_format = FMT_PCM16, .sample_rate = 48000, .channel_count = 1, .pitch = 1},
        .valid = {1, 1}, .adpcm = {.buffer = -1}};
    v.buffers[0] = (AudrenWaveBuffer){.address = (uintptr_t)first, .size = sizeof first, .end = 100, .end_of_stream = 1};
    v.buffers[1] = (AudrenWaveBuffer){.address = (uintptr_t)second, .size = sizeof second, .end = 480};
    float out[6][MAX_FRAME] = {{0}};
    int failed = 0;
    for (int scenario = 0; scenario < 3; scenario++) {
        v.buffers[0].end_of_stream = scenario != 1;
        v.buffers[0].loop = scenario == 2; v.buffers[0].loop_count = -1;
        voice_render(&r, &v, out, 240);
        for (int i = 0; i < 240; i++) {
            float want = i < 100 || scenario == 2 ? .25f : scenario == 1 || AUDIO_EOS_PLAYS_ON ? -.5f : 0;
            if (fabsf(out[0][i] - want) > 1e-6f) {
                fprintf(stderr, "EOS samples scenario %d sample %d: %g != %g\n", scenario, i, out[0][i], want);
                failed = 1; break;
            }
        }
    }
    /* An empty EOS encountered after a partial buffer has the same boundary as a non-empty EOS. */
    v.buffers[0].loop = 0; v.buffers[0].end_of_stream = 0;
    v.buffers[2] = v.buffers[1]; v.buffers[1] = (AudrenWaveBuffer){.end_of_stream = 1}; v.valid[2] = 1;
    voice_render(&r, &v, out, 240);
    for (int i = 0; i < 240; i++) {
        float want = i < 100 ? .25f : AUDIO_EOS_PLAYS_ON ? -.5f : 0;
        if (fabsf(out[0][i] - want) > 1e-6f) { failed = 1; fprintf(stderr, "empty EOS sample %d\n", i); break; }
    }
    puts("4 EOS sample paths checked (stream boundary, continuous, loop, empty EOS)");
    return failed;
}

int main(void) {
    setenv("TOTK_AUDIO_OFF", "1", 1); unsetenv("TOTK_AUDIO_CAPTURE");
    int failed = eos_samples();
    for (int i = 0; i < 4; ++i) failed += run_case(i, 100, 100, 1.0f);
    failed += run_case(0, 0, 0, 0.5f);       /* saved mute is active before the first rendered sample */
    failed += run_case(0, 100, 0, 0.25f);    /* gain changes ramp over 20 ms without altering guest volume */
    runtime_audio_master_volume_set(-1);
    if (atomic_load(&master_volume_target) != 0.0f) { fprintf(stderr, "master volume lower bound was not clamped\n"); failed++; }
    runtime_audio_master_volume_set(101);
    if (atomic_load(&master_volume_target) != 1.0f) { fprintf(stderr, "master volume upper bound was not clamped\n"); failed++; }
    if (failed) return 1;
    puts("4 audio routing graphs / 64 stereo frames (128 channel samples) passed");
    puts("saved mute, guest volume separation, clamp, 20 ms ramp completion/reversal, and settled mute passed");
    return 0;
}
