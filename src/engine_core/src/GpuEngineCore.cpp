#include "GpuEngineCore.h"
#include "CudaProcessor.h"

#define _USE_MATH_DEFINES
#include <algorithm>
#include <chrono>
#include <cstring>
#include <stdexcept>
#include <string>
#include <cmath>
#include <vector>
#include <iostream>
#include <sstream>
#include <cstdlib>

namespace gpuengine
{
namespace
{
constexpr int kDefaultWorkerCount = 2;
constexpr double kEmptyValueSentinel = 2147483647.0; // mirrors EMPTY_VALUE in MQL5
constexpr double kPi    = 3.14159265358979323846;
constexpr double kTwoPi = 6.28318530717958647692;

inline double Clamp(double value, double min_value, double max_value)
{
    if(value < min_value) return min_value;
    if(value > max_value) return max_value;
    return value;
}

inline double NormalizeTwoPi(double angle)
{
    double res = std::fmod(angle, kTwoPi);
    if(res < 0.0)
        res += kTwoPi;
    return res;
}


bool DebugEnabled()
{
    static int state = -1;
    if(state == -1)
    {
        const char* env = std::getenv("GPU_ENGINE_DEBUG");
        if(env && (_stricmp(env, "0") == 0 || _stricmp(env, "false") == 0 || _stricmp(env, "off") == 0))
            state = 0;
        else
            state = (env ? 1 : 0);
    }
    return state == 1;
}

void DebugLog(const std::string& message)
{
    if(!DebugEnabled())
        return;
    std::cout << "[Kalman] " << message << std::endl;
}


void RunKalmanTracker(JobRecord& job)
{
    const int frame_count  = job.desc.frame_count;
    const int frame_length = job.desc.frame_length;
    const std::size_t total = static_cast<std::size_t>(frame_count) * frame_length;
    const int cycle_count  = static_cast<int>(job.cycle_periods.size());

    job.phase.assign(total, 0.0);
    job.phase_unwrapped.assign(total, 0.0);
    job.amplitude.assign(total, 0.0);
    job.inst_period.assign(total, 0.0);
    job.inst_frequency.assign(total, 0.0);
    job.eta.assign(total, 0.0);
    job.countdown.assign(total, 0.0);
    job.direction.assign(total, 0.0);
    job.power.assign(total, 0.0);
    job.velocity.assign(total, 0.0);
    job.recon.assign(total, 0.0);
    job.kalman_line.assign(total, 0.0);
    job.turn_signal.assign(total, 0.0);
    job.confidence.assign(total, 0.0);
    job.amp_delta.assign(total, 0.0);

    job.phase_all.clear();
    job.phase_unwrapped_all.clear();
    job.amplitude_all.clear();
    job.inst_period_all.clear();
    job.inst_frequency_all.clear();
    job.eta_all.clear();
    job.countdown_all.clear();
    job.direction_all.clear();
    job.recon_all.clear();
    job.kalman_all.clear();
    job.turn_all.clear();
    job.confidence_all.clear();
    job.amp_delta_all.clear();
    job.power_all.clear();
    job.velocity_all.clear();
    job.plv_cycle.clear();
    job.snr_cycle.clear();

    job.result.dominant_cycle = -1;
    job.result.dominant_period = 0.0;
    job.result.dominant_snr = 0.0;
    job.result.dominant_plv = 0.0;
    job.result.dominant_confidence = 0.0;
    job.result.line_phase_deg = 0.0;
    job.result.line_amplitude = 0.0;
    job.result.line_period = 0.0;
    job.result.line_eta = 0.0;
    job.result.line_confidence = 0.0;
    job.result.line_value = 0.0;

    if(total == 0 || cycle_count <= 0 || job.cycles.empty())
    {
        job.result.cycle_count = 0;
        return;
    }

    const KalmanParams& kalman_params = job.desc.kalman;
    double process_noise     = std::max(kalman_params.process_noise, 1.0e-8);
    double measurement_noise = std::max(kalman_params.measurement_noise, 1.0e-8);
    double init_variance     = std::max(kalman_params.init_variance, 1.0e-6);

    switch(kalman_params.preset)
    {
        case KalmanPreset::Smooth:
            process_noise     = 5.0e-5;
            measurement_noise = 4.0e-3;
            init_variance     = 0.25;
            break;
        case KalmanPreset::Balanced:
            process_noise     = 1.0e-4;
            measurement_noise = 2.5e-3;
            init_variance     = 0.5;
            break;
        case KalmanPreset::Reactive:
            process_noise     = 4.0e-4;
            measurement_noise = 1.5e-3;
            init_variance     = 0.75;
            break;
        case KalmanPreset::Manual:
        default:
            break;
    }

    const double plv_threshold = Clamp(kalman_params.plv_threshold, 0.0, 1.0);
    const double freq_epsilon  = std::max(kalman_params.convergence_eps, 1.0e-6);

    {
        std::ostringstream oss;
        oss << "Job user_tag=" << job.desc.user_tag
            << " frame_length=" << frame_length
            << " frame_count=" << frame_count
            << " requested_cycles=" << cycle_count
            << " plv_threshold=" << plv_threshold;
        DebugLog(oss.str());
    }

    double noise_energy = 0.0;
    int    noise_samples = 0;
    for(double v : job.noise)
    {
        if(std::isfinite(v))
        {
            noise_energy += v * v;
            ++noise_samples;
        }
    }
    if(noise_samples > 0)
        noise_energy /= static_cast<double>(noise_samples);
    else
        noise_energy = 0.0;

    const std::size_t per_cycle_span = total;
    std::vector<double> selected_cycles;
    std::vector<double> phase_all_out;
    std::vector<double> phase_unwrap_all_out;
    std::vector<double> amplitude_all_out;
    std::vector<double> inst_period_all_out;
    std::vector<double> inst_frequency_all_out;
    std::vector<double> eta_all_out;
    std::vector<double> countdown_all_out;
    std::vector<double> direction_all_out;
    std::vector<double> recon_all_out;
    std::vector<double> kalman_all_out;
    std::vector<double> turn_all_out;
    std::vector<double> confidence_all_out;
    std::vector<double> amp_delta_all_out;
    std::vector<double> power_all_out;
    std::vector<double> velocity_all_out;

    selected_cycles.reserve(static_cast<std::size_t>(cycle_count) * per_cycle_span);
    phase_all_out.reserve(static_cast<std::size_t>(cycle_count) * per_cycle_span);
    phase_unwrap_all_out.reserve(static_cast<std::size_t>(cycle_count) * per_cycle_span);
    amplitude_all_out.reserve(static_cast<std::size_t>(cycle_count) * per_cycle_span);
    inst_period_all_out.reserve(static_cast<std::size_t>(cycle_count) * per_cycle_span);
    inst_frequency_all_out.reserve(static_cast<std::size_t>(cycle_count) * per_cycle_span);
    eta_all_out.reserve(static_cast<std::size_t>(cycle_count) * per_cycle_span);
    countdown_all_out.reserve(static_cast<std::size_t>(cycle_count) * per_cycle_span);
    direction_all_out.reserve(static_cast<std::size_t>(cycle_count) * per_cycle_span);
    recon_all_out.reserve(static_cast<std::size_t>(cycle_count) * per_cycle_span);
    kalman_all_out.reserve(static_cast<std::size_t>(cycle_count) * per_cycle_span);
    turn_all_out.reserve(static_cast<std::size_t>(cycle_count) * per_cycle_span);
    confidence_all_out.reserve(static_cast<std::size_t>(cycle_count) * per_cycle_span);
    amp_delta_all_out.reserve(static_cast<std::size_t>(cycle_count) * per_cycle_span);
    power_all_out.reserve(static_cast<std::size_t>(cycle_count) * per_cycle_span);
    velocity_all_out.reserve(static_cast<std::size_t>(cycle_count) * per_cycle_span);

    std::vector<double> selected_periods;
    std::vector<double> selected_plv;
    std::vector<double> selected_snr;
    std::vector<double> final_phase_deg;
    std::vector<double> final_amplitude;
    std::vector<double> final_period;
    std::vector<double> final_eta;
    std::vector<double> final_confidence;
    std::vector<double> final_value;

    selected_periods.reserve(cycle_count);
    selected_plv.reserve(cycle_count);
    selected_snr.reserve(cycle_count);
    final_phase_deg.reserve(cycle_count);
    final_amplitude.reserve(cycle_count);
    final_period.reserve(cycle_count);
    final_eta.reserve(cycle_count);
    final_confidence.reserve(cycle_count);
    final_value.reserve(cycle_count);

    std::vector<double> best_cycle;
    std::vector<double> best_phase_all;
    std::vector<double> best_phase_unwrap_all;
    std::vector<double> best_amplitude_all;
    std::vector<double> best_inst_period_all;
    std::vector<double> best_inst_frequency_all;
    std::vector<double> best_eta_all;
    std::vector<double> best_countdown_all;
    std::vector<double> best_direction_all;
    std::vector<double> best_recon_all;
    std::vector<double> best_kalman_all;
    std::vector<double> best_turn_all;
    std::vector<double> best_confidence_all;
    std::vector<double> best_amp_delta_all;
    std::vector<double> best_power_all;
    std::vector<double> best_velocity_all;
    double best_final_phase = 0.0;
    double best_final_amplitude = 0.0;
    double best_final_period = 0.0;
    double best_final_eta = 0.0;
    double best_final_confidence = 0.0;
    double best_final_value = 0.0;
    double best_attempt_snr = 0.0;
    bool   have_best_candidate = false;

    double best_attempt_plv = 0.0;
    double best_attempt_period = 0.0;

    for(int c = 0; c < cycle_count; ++c)
    {
        const std::size_t offset = static_cast<std::size_t>(c) * per_cycle_span;
        if(offset + per_cycle_span > job.cycles.size())
            break;

        double period = (c < static_cast<int>(job.cycle_periods.size()) ? job.cycle_periods[c] : 0.0);
        if(period <= 0.0)
            continue;

        const double omega = kTwoPi / std::max(period, 1.0);
        if(!std::isfinite(omega))
            continue;

        const double* cycle_ptr = job.cycles.data() + offset;

        std::vector<double> phase_deg(per_cycle_span, 0.0);
        std::vector<double> phase_unwrap_deg(per_cycle_span, 0.0);
        std::vector<double> amplitude_vec(per_cycle_span, 0.0);
        std::vector<double> inst_period_vec(per_cycle_span, 0.0);
        std::vector<double> inst_freq_vec(per_cycle_span, 0.0);
        std::vector<double> eta_vec(per_cycle_span, 0.0);
        std::vector<double> countdown_vec(per_cycle_span, 0.0);
        std::vector<double> direction_vec(per_cycle_span, 0.0);
        std::vector<double> recon_vec(per_cycle_span, 0.0);
        std::vector<double> kalman_vec(per_cycle_span, 0.0);
        std::vector<double> turn_vec(per_cycle_span, 0.0);
        std::vector<double> confidence_vec(per_cycle_span, 0.0);
        std::vector<double> amp_delta_vec(per_cycle_span, 0.0);
        std::vector<double> power_vec(per_cycle_span, 0.0);
        std::vector<double> velocity_vec(per_cycle_span, 0.0);

        double x0 = cycle_ptr[0];
        double x1 = 0.0;
        double P00 = init_variance;
        double P01 = 0.0;
        double P11 = init_variance;

        double sum_cos = 0.0;
        double sum_sin = 0.0;
        double unwrapped = 0.0;
        double prev_phase_mod = 0.0;
        bool   prev_phase_valid = false;
        double prev_amp = std::abs(x0);
        double energy = 0.0;
        bool   valid = true;
        std::string invalid_reason;

        const double freq_value = omega / kTwoPi;
        const double inst_period_value = kTwoPi / std::max(omega, freq_epsilon);

        for(std::size_t i = 0; i < per_cycle_span; ++i)
        {
            const double sample = cycle_ptr[i];
            const double cosw = std::cos(omega);
            const double sinw = std::sin(omega);

            const double x0_pred = cosw * x0 - sinw * x1;
            const double x1_pred = sinw * x0 + cosw * x1;

            const double P00_pred = cosw * cosw * P00 - 2.0 * cosw * sinw * P01 + sinw * sinw * P11 + process_noise;
            const double P01_pred = cosw * sinw * P00 + (cosw * cosw - sinw * sinw) * P01 - cosw * sinw * P11;
            const double P11_pred = sinw * sinw * P00 + 2.0 * cosw * sinw * P01 + cosw * cosw * P11 + process_noise;

            const double innovation = sample - x0_pred;
            if(!std::isfinite(innovation))
            {
                valid = false;
                invalid_reason = "innovation not finite";
                break;
            }

            const double S = P00_pred + measurement_noise;
            if(!std::isfinite(S) || S <= 0.0)
            {
                valid = false;
                invalid_reason = "covariance invalid";
                break;
            }

            const double K0 = P00_pred / S;
            const double K1 = P01_pred / S;

            x0 = x0_pred + K0 * innovation;
            x1 = x1_pred + K1 * innovation;

            if(!std::isfinite(x0) || !std::isfinite(x1))
            {
                valid = false;
                invalid_reason = "state not finite";
                break;
            }

            const double P00_new = (1.0 - K0) * P00_pred;
            const double P01_new = (1.0 - K0) * P01_pred;
            const double P11_new = P11_pred - K1 * P01_pred;

            P00 = P00_new;
            P01 = P01_new;
            P11 = P11_new;

            double phase = std::atan2(x1, x0);
            if(phase < 0.0)
                phase += kTwoPi;

            double delta_phase = 0.0;
            double turn_flag = 0.0;
            if(prev_phase_valid)
            {
                delta_phase = phase - prev_phase_mod;
                if(delta_phase > kPi)
                {
                    delta_phase -= kTwoPi;
                    turn_flag = -1.0;
                }
                else if(delta_phase < -kPi)
                {
                    delta_phase += kTwoPi;
                    turn_flag = 1.0;
                }
                unwrapped += delta_phase;
            }
            else
            {
                unwrapped = phase;
                prev_phase_valid = true;
            }
            prev_phase_mod = phase;

            sum_cos += std::cos(phase);
            sum_sin += std::sin(phase);

            const double amplitude = std::sqrt(std::max(x0 * x0 + x1 * x1, 0.0));
            const double eta = (kTwoPi - phase) / std::max(omega, freq_epsilon);
            const double eta_clamped = std::max(eta, 0.0);
            const double direction = (phase < kPi) ? -1.0 : 1.0;

            double countdown = eta_clamped;
            if(direction < 0.0)
                countdown = -countdown;
            if(turn_flag != 0.0)
                countdown = (direction < 0.0 ? -1.0 : 1.0);

            const double recon = amplitude * std::cos(phase);
            const double confidence = 1.0 / (1.0 + std::fabs(innovation) / (std::fabs(sample) + 1.0e-6));
            const double amp_delta = amplitude - prev_amp;

            phase_deg[i]        = phase * 180.0 / kPi;
            phase_unwrap_deg[i] = unwrapped * 180.0 / kPi;
            amplitude_vec[i]    = amplitude;
            inst_period_vec[i]  = inst_period_value;
            inst_freq_vec[i]    = freq_value;
            eta_vec[i]          = eta_clamped;
            countdown_vec[i]    = countdown;
            direction_vec[i]    = direction;
            recon_vec[i]        = recon;
            kalman_vec[i]       = x0;
            turn_vec[i]         = (turn_flag != 0.0 ? direction : 0.0);
            confidence_vec[i]   = confidence;
            amp_delta_vec[i]    = amp_delta;
            power_vec[i]        = amplitude * amplitude;
            velocity_vec[i]     = freq_value;

            prev_amp = amplitude;
            energy  += sample * sample;
        }

        if(!valid)
        {
            std::ostringstream oss;
            oss << "cycle#" << c << " period=" << period << " rejected: " << invalid_reason;
            DebugLog(oss.str());
            continue;
        }

        double plv = std::sqrt(sum_cos * sum_cos + sum_sin * sum_sin) / std::max<double>(per_cycle_span, 1.0);
        if(!std::isfinite(plv))
            plv = 0.0;

        double snr = 0.0;
        if(noise_energy > 1.0e-12)
            snr = energy / std::max(noise_energy, 1.0e-12);

        if(plv > best_attempt_plv)
        {
            best_attempt_plv = plv;
            best_attempt_period = period;
            best_attempt_snr = snr;
            best_cycle.assign(cycle_ptr, cycle_ptr + per_cycle_span);
            best_phase_all = phase_deg;
            best_phase_unwrap_all = phase_unwrap_deg;
            best_amplitude_all = amplitude_vec;
            best_inst_period_all = inst_period_vec;
            best_inst_frequency_all = inst_freq_vec;
            best_eta_all = eta_vec;
            best_countdown_all = countdown_vec;
            best_direction_all = direction_vec;
            best_recon_all = recon_vec;
            best_kalman_all = kalman_vec;
            best_turn_all = turn_vec;
            best_confidence_all = confidence_vec;
            best_amp_delta_all = amp_delta_vec;
            best_power_all = power_vec;
            best_velocity_all = velocity_vec;
            if(!phase_deg.empty())
            {
                best_final_phase = phase_deg.back();
                best_final_amplitude = amplitude_vec.back();
                best_final_period = inst_period_vec.back();
                best_final_eta = eta_vec.back();
                best_final_confidence = confidence_vec.back();
                best_final_value = kalman_vec.back();
            }
            have_best_candidate = true;
        }

        if(plv < plv_threshold)
        {
            std::ostringstream oss;
            oss << "cycle#" << c << " period=" << period << " plv=" << plv << " (< threshold)";
            DebugLog(oss.str());
            continue;
        }

        {
            std::ostringstream oss;
            oss << "cycle#" << c << " period=" << period << " plv=" << plv << " snr=" << snr << " accepted";
            DebugLog(oss.str());
        }

        selected_periods.push_back(period);
        selected_plv.push_back(plv);
        selected_snr.push_back(snr);

        selected_cycles.insert(selected_cycles.end(), cycle_ptr, cycle_ptr + per_cycle_span);
        phase_all_out.insert(phase_all_out.end(), phase_deg.begin(), phase_deg.end());
        phase_unwrap_all_out.insert(phase_unwrap_all_out.end(), phase_unwrap_deg.begin(), phase_unwrap_deg.end());
        amplitude_all_out.insert(amplitude_all_out.end(), amplitude_vec.begin(), amplitude_vec.end());
        inst_period_all_out.insert(inst_period_all_out.end(), inst_period_vec.begin(), inst_period_vec.end());
        inst_frequency_all_out.insert(inst_frequency_all_out.end(), inst_freq_vec.begin(), inst_freq_vec.end());
        eta_all_out.insert(eta_all_out.end(), eta_vec.begin(), eta_vec.end());
        countdown_all_out.insert(countdown_all_out.end(), countdown_vec.begin(), countdown_vec.end());
        direction_all_out.insert(direction_all_out.end(), direction_vec.begin(), direction_vec.end());
        recon_all_out.insert(recon_all_out.end(), recon_vec.begin(), recon_vec.end());
        kalman_all_out.insert(kalman_all_out.end(), kalman_vec.begin(), kalman_vec.end());
        turn_all_out.insert(turn_all_out.end(), turn_vec.begin(), turn_vec.end());
        confidence_all_out.insert(confidence_all_out.end(), confidence_vec.begin(), confidence_vec.end());
        amp_delta_all_out.insert(amp_delta_all_out.end(), amp_delta_vec.begin(), amp_delta_vec.end());
        power_all_out.insert(power_all_out.end(), power_vec.begin(), power_vec.end());
        velocity_all_out.insert(velocity_all_out.end(), velocity_vec.begin(), velocity_vec.end());

        final_phase_deg.push_back(phase_deg.back());
        final_amplitude.push_back(amplitude_vec.back());
        final_period.push_back(inst_period_vec.back());
        final_eta.push_back(eta_vec.back());
        final_confidence.push_back(confidence_vec.back());
        final_value.push_back(kalman_vec.back());
    }

    const int valid_cycles = static_cast<int>(selected_periods.size());
    job.result.cycle_count = valid_cycles;
    if(valid_cycles == 0)
    {
        if(have_best_candidate && !best_cycle.empty())
        {
            job.result.cycle_count = 1;
            job.cycle_periods.assign(1, best_attempt_period);
            job.plv_cycle.assign(1, best_attempt_plv);
            job.snr_cycle.assign(1, best_attempt_snr);
            job.cycles = best_cycle;
            job.phase_all = best_phase_all;
            job.phase_unwrapped_all = best_phase_unwrap_all;
            job.amplitude_all = best_amplitude_all;
            job.inst_period_all = best_inst_period_all;
            job.inst_frequency_all = best_inst_frequency_all;
            job.eta_all = best_eta_all;
            job.countdown_all = best_countdown_all;
            job.direction_all = best_direction_all;
            job.recon_all = best_recon_all;
            job.kalman_all = best_kalman_all;
            job.turn_all = best_turn_all;
            job.confidence_all = best_confidence_all;
            job.amp_delta_all = best_amp_delta_all;
            job.power_all = best_power_all;
            job.velocity_all = best_velocity_all;
            job.phase = best_phase_all;
            job.phase_unwrapped = best_phase_unwrap_all;
            job.amplitude = best_amplitude_all;
            job.inst_period = best_inst_period_all;
            job.inst_frequency = best_inst_frequency_all;
            job.eta = best_eta_all;
            job.countdown = best_countdown_all;
            job.direction = best_direction_all;
            job.recon = best_recon_all;
            job.kalman_line = best_kalman_all;
            job.turn_signal = best_turn_all;
            job.confidence = best_confidence_all;
            job.amp_delta = best_amp_delta_all;
            job.power = best_power_all;
            job.velocity = best_velocity_all;
            job.result.dominant_cycle = 0;
            job.result.dominant_plv = best_attempt_plv;
            job.result.dominant_period = best_attempt_period;
            job.result.dominant_snr = best_attempt_snr;
            job.result.dominant_confidence = best_final_confidence;
            job.result.line_phase_deg = best_final_phase;
            job.result.line_amplitude = best_final_amplitude;
            job.result.line_period = best_final_period;
            job.result.line_eta = best_final_eta;
            job.result.line_confidence = best_final_confidence;
            job.result.line_value = best_final_value;
            DebugLog("fallback promoted best candidate despite low PLV");
            return;
        }
        // Fallback: preserve the original cycles as-is instead of reporting zero.
        const int original_cycles = cycle_count;
        job.result.cycle_count = original_cycles;
        job.plv_cycle.assign(std::max(original_cycles, 0), 0.0);
        job.snr_cycle.assign(std::max(original_cycles, 0), 0.0);
        {
            std::ostringstream oss;
            oss << "no cycles accepted; best_plv=" << best_attempt_plv
                << " best_period=" << best_attempt_period
                << " original_cycles=" << original_cycles;
            DebugLog(oss.str());
        }
        // Keep the original period list; nothing else to do.
        return;
    }

    job.cycle_periods = selected_periods;
    job.plv_cycle = selected_plv;
    job.snr_cycle = selected_snr;

    job.cycles.swap(selected_cycles);
    job.phase_all.swap(phase_all_out);
    job.phase_unwrapped_all.swap(phase_unwrap_all_out);
    job.amplitude_all.swap(amplitude_all_out);
    job.inst_period_all.swap(inst_period_all_out);
    job.inst_frequency_all.swap(inst_frequency_all_out);
    job.eta_all.swap(eta_all_out);
    job.countdown_all.swap(countdown_all_out);
    job.direction_all.swap(direction_all_out);
    job.recon_all.swap(recon_all_out);
    job.kalman_all.swap(kalman_all_out);
    job.turn_all.swap(turn_all_out);
    job.confidence_all.swap(confidence_all_out);
    job.amp_delta_all.swap(amp_delta_all_out);
    job.power_all.swap(power_all_out);
    job.velocity_all.swap(velocity_all_out);

    int best_index = 0;
    double best_plv = selected_plv[0];
    for(int i = 1; i < valid_cycles; ++i)
    {
        if(selected_plv[i] > best_plv)
        {
            best_plv = selected_plv[i];
            best_index = i;
        }
    }

    job.result.dominant_cycle = best_index;
    job.result.dominant_plv   = best_plv;
    job.result.dominant_period = selected_periods[best_index];
    job.result.dominant_snr   = selected_snr[best_index];
    job.result.dominant_confidence = final_confidence[best_index];

    const std::size_t best_offset = static_cast<std::size_t>(best_index) * per_cycle_span;
    auto copy_component = [&](std::vector<double>& dst, const std::vector<double>& src)
    {
        if(src.empty() || dst.empty())
            return;
        std::copy(src.begin() + best_offset, src.begin() + best_offset + per_cycle_span, dst.begin());
    };

    copy_component(job.phase, job.phase_all);
    copy_component(job.phase_unwrapped, job.phase_unwrapped_all);
    copy_component(job.amplitude, job.amplitude_all);
    copy_component(job.inst_period, job.inst_period_all);
    copy_component(job.inst_frequency, job.inst_frequency_all);
    copy_component(job.eta, job.eta_all);
    copy_component(job.countdown, job.countdown_all);
    copy_component(job.direction, job.direction_all);
    copy_component(job.recon, job.recon_all);
    copy_component(job.kalman_line, job.kalman_all);
    copy_component(job.turn_signal, job.turn_all);
    copy_component(job.confidence, job.confidence_all);
    copy_component(job.amp_delta, job.amp_delta_all);
    copy_component(job.power, job.power_all);
    copy_component(job.velocity, job.velocity_all);

    if(per_cycle_span > 0)
    {
        const std::size_t last = per_cycle_span - 1;
        job.result.line_phase_deg  = job.phase[last];
        job.result.line_amplitude  = job.amplitude[last];
        job.result.line_period     = job.inst_period[last];
        job.result.line_eta        = job.eta[last];
        job.result.line_confidence = job.confidence[last];
        job.result.line_value      = job.kalman_line[last];
    }
}

} // namespace

Engine::Engine() = default;
Engine::~Engine()
{
    Shutdown();
}

int Engine::Initialize(const Config& cfg)
{
    if(cfg.window_size <= 0 || cfg.max_batch_size <= 0 || cfg.max_cycle_count < 0)
    {
        std::lock_guard<std::mutex> lock(m_error_mutex);
        m_last_error = "Invalid configuration";
        return STATUS_INVALID_CONFIG;
    }

    ResetState();
    m_config = cfg;
    m_running = true;

    m_processor = std::make_unique<CudaProcessor>();
    int gpu_status = m_processor->Initialize(cfg);
    if(gpu_status != STATUS_OK)
    {
        std::lock_guard<std::mutex> lock(m_error_mutex);
        m_last_error = "Failed to initialise CUDA processor";
        m_running = false;
        m_processor.reset();
        return gpu_status;
    }

    const int worker_count = std::max(1, std::max(cfg.stream_count, kDefaultWorkerCount));
    for(int i=0;i<worker_count;++i)
    {
        m_workers.emplace_back([this](){ WorkerLoop(); });
    }

    return STATUS_OK;
}

void Engine::ResetState()
{
    Shutdown();
    m_jobs.clear();
    while(!m_job_queue.empty())
        m_job_queue.pop();
    m_total_ms = 0.0;
    m_max_ms   = 0.0;
    m_completed_jobs = 0ULL;
    m_next_id = 1ULL;
}

void Engine::Shutdown()
{
    bool was_running = m_running.exchange(false);

    {
        std::lock_guard<std::mutex> lock(m_queue_mutex);
        while(!m_job_queue.empty())
            m_job_queue.pop();
    }
    m_queue_cv.notify_all();

    if(was_running)
    {
        for(auto& worker: m_workers)
        {
            if(worker.joinable())
                worker.join();
        }
    }
    m_workers.clear();

    if(m_processor)
    {
        m_processor->Shutdown();
        m_processor.reset();
    }
}

int Engine::SubmitJob(const JobDesc& desc, JobHandle& out_handle)
{
    if(!m_running.load())
        return STATUS_NOT_INITIALISED;

    if(desc.frames == nullptr || desc.frame_count <= 0 || desc.frame_length <= 0)
    {
        std::lock_guard<std::mutex> lock(m_error_mutex);
        m_last_error = "SubmitJob: invalid frame parameters";
        return STATUS_INVALID_CONFIG;
    }
    if(desc.cycles.count > m_config.max_cycle_count)
    {
        std::lock_guard<std::mutex> lock(m_error_mutex);
        m_last_error = "SubmitJob: cycle_count exceeds max_cycle_count";
        return STATUS_INVALID_CONFIG;
    }
    if(desc.cycles.count > 0 && desc.cycles.periods == nullptr)
    {
        std::lock_guard<std::mutex> lock(m_error_mutex);
        m_last_error = "SubmitJob: cycle periods pointer is null";
        return STATUS_INVALID_CONFIG;
    }

    auto record = std::make_shared<JobRecord>();
    record->desc = desc;
    const int total = desc.frame_count * desc.frame_length;
    record->input_copy.assign(desc.frames, desc.frames + total);
    const bool has_preview_mask = (desc.preview_mask != nullptr && desc.preview_mask[0] != kEmptyValueSentinel);
    if(has_preview_mask)
    {
        const int freq_bins = desc.frame_length / 2 + 1;
        record->preview_mask.assign(desc.preview_mask,
                                    desc.preview_mask + freq_bins);
        record->desc.preview_mask = record->preview_mask.data();
    }
    else
    {
        record->preview_mask.clear();
        record->desc.preview_mask = nullptr;
    }

    const bool has_cycle_periods = (desc.cycles.count > 0 && desc.cycles.periods != nullptr && desc.cycles.periods[0] != kEmptyValueSentinel);
    if(has_cycle_periods)
    {
        record->cycle_periods.assign(desc.cycles.periods,
                                     desc.cycles.periods + desc.cycles.count);
        record->desc.cycles.periods = record->cycle_periods.data();
    }
    record->wave.reserve(total);
    record->preview.reserve(total);
    record->cycles.reserve(static_cast<std::size_t>(std::max(desc.cycles.count, 1)) * total);
    record->noise.reserve(total);
    record->phase.reserve(total);
    record->amplitude.reserve(total);
    record->inst_period.reserve(total);
    record->eta.reserve(total);
    record->recon.reserve(total);
    record->confidence.reserve(total);
    record->amp_delta.reserve(total);
    record->submit_time = std::chrono::steady_clock::now();

    JobHandle handle;
    handle.internal_id = m_next_id.fetch_add(1ULL);
    handle.user_tag    = desc.user_tag;
    record->handle = handle;
    record->result.user_tag = desc.user_tag;
    record->result.frame_count = desc.frame_count;
    record->result.frame_length = desc.frame_length;
    record->result.cycle_count  = desc.cycles.count;

    {
        std::lock_guard<std::mutex> lock(m_queue_mutex);
        m_jobs.emplace(handle.internal_id, record);
        m_job_queue.push(handle.internal_id);
    }
    m_queue_cv.notify_one();

    out_handle = handle;
    return STATUS_OK;
}

int Engine::PollStatus(const JobHandle& handle, int& out_status)
{
    auto it = m_jobs.find(handle.internal_id);
    if(it == m_jobs.end())
    {
        out_status = STATUS_ERROR;
        return STATUS_ERROR;
    }
    out_status = it->second->status.load();
    return STATUS_OK;
}

int Engine::FetchResult(const JobHandle& handle,
                        double* wave_out,
                        double* preview_out,
                        double* cycles_out,
                        double* noise_out,
                        double* phase_out,
                        double* phase_unwrapped_out,
                        double* amplitude_out,
                        double* period_out,
                        double* frequency_out,
                        double* eta_out,
                        double* countdown_out,
                        double* recon_out,
                        double* kalman_out,
                        double* confidence_out,
                        double* amp_delta_out,
                        double* turn_signal_out,
                        double* direction_out,
                        double* power_out,
                        double* velocity_out,
                        double* phase_all_out,
                        double* phase_unwrapped_all_out,
                        double* amplitude_all_out,
                        double* period_all_out,
                        double* frequency_all_out,
                        double* eta_all_out,
                        double* countdown_all_out,
                        double* direction_all_out,
                        double* recon_all_out,
                        double* kalman_all_out,
                        double* turn_all_out,
                        double* confidence_all_out,
                        double* amp_delta_all_out,
                        double* power_all_out,
                        double* velocity_all_out,
                        double* plv_cycles_out,
                        double* snr_cycles_out,
                        ResultInfo& info)
{
    auto it = m_jobs.find(handle.internal_id);
    if(it == m_jobs.end())
        return STATUS_ERROR;

    auto record = it->second;
    if(record->status.load() != STATUS_READY)
        return STATUS_IN_PROGRESS;

    const int total = record->desc.frame_count * record->desc.frame_length;

    if(wave_out)
        std::copy(record->wave.begin(), record->wave.end(), wave_out);
    if(preview_out)
        std::copy(record->preview.begin(), record->preview.end(), preview_out);
    if(cycles_out && !record->cycles.empty())
        std::copy(record->cycles.begin(), record->cycles.end(), cycles_out);
    if(noise_out)
        std::copy(record->noise.begin(), record->noise.end(), noise_out);
    if(phase_out && !record->phase.empty())
        std::copy(record->phase.begin(), record->phase.end(), phase_out);
    if(phase_unwrapped_out && !record->phase_unwrapped.empty())
        std::copy(record->phase_unwrapped.begin(), record->phase_unwrapped.end(), phase_unwrapped_out);
    if(amplitude_out && !record->amplitude.empty())
        std::copy(record->amplitude.begin(), record->amplitude.end(), amplitude_out);
    if(period_out && !record->inst_period.empty())
        std::copy(record->inst_period.begin(), record->inst_period.end(), period_out);
    if(frequency_out && !record->inst_frequency.empty())
        std::copy(record->inst_frequency.begin(), record->inst_frequency.end(), frequency_out);
    if(eta_out && !record->eta.empty())
        std::copy(record->eta.begin(), record->eta.end(), eta_out);
    if(countdown_out && !record->countdown.empty())
        std::copy(record->countdown.begin(), record->countdown.end(), countdown_out);
    if(kalman_out && !record->kalman_line.empty())
        std::copy(record->kalman_line.begin(), record->kalman_line.end(), kalman_out);
    if(recon_out && !record->recon.empty())
        std::copy(record->recon.begin(), record->recon.end(), recon_out);
    if(confidence_out && !record->confidence.empty())
        std::copy(record->confidence.begin(), record->confidence.end(), confidence_out);
    if(amp_delta_out && !record->amp_delta.empty())
        std::copy(record->amp_delta.begin(), record->amp_delta.end(), amp_delta_out);
    if(turn_signal_out && !record->turn_signal.empty())
        std::copy(record->turn_signal.begin(), record->turn_signal.end(), turn_signal_out);
    if(direction_out && !record->direction.empty())
        std::copy(record->direction.begin(), record->direction.end(), direction_out);
    if(power_out && !record->power.empty())
        std::copy(record->power.begin(), record->power.end(), power_out);
    if(velocity_out && !record->velocity.empty())
        std::copy(record->velocity.begin(), record->velocity.end(), velocity_out);

    if(phase_all_out && !record->phase_all.empty())
        std::copy(record->phase_all.begin(), record->phase_all.end(), phase_all_out);
    if(phase_unwrapped_all_out && !record->phase_unwrapped_all.empty())
        std::copy(record->phase_unwrapped_all.begin(), record->phase_unwrapped_all.end(), phase_unwrapped_all_out);
    if(amplitude_all_out && !record->amplitude_all.empty())
        std::copy(record->amplitude_all.begin(), record->amplitude_all.end(), amplitude_all_out);
    if(period_all_out && !record->inst_period_all.empty())
        std::copy(record->inst_period_all.begin(), record->inst_period_all.end(), period_all_out);
    if(frequency_all_out && !record->inst_frequency_all.empty())
        std::copy(record->inst_frequency_all.begin(), record->inst_frequency_all.end(), frequency_all_out);
    if(eta_all_out && !record->eta_all.empty())
        std::copy(record->eta_all.begin(), record->eta_all.end(), eta_all_out);
    if(countdown_all_out && !record->countdown_all.empty())
        std::copy(record->countdown_all.begin(), record->countdown_all.end(), countdown_all_out);
    if(direction_all_out && !record->direction_all.empty())
        std::copy(record->direction_all.begin(), record->direction_all.end(), direction_all_out);
    if(recon_all_out && !record->recon_all.empty())
        std::copy(record->recon_all.begin(), record->recon_all.end(), recon_all_out);
    if(kalman_all_out && !record->kalman_all.empty())
        std::copy(record->kalman_all.begin(), record->kalman_all.end(), kalman_all_out);
    if(turn_all_out && !record->turn_all.empty())
        std::copy(record->turn_all.begin(), record->turn_all.end(), turn_all_out);
    if(confidence_all_out && !record->confidence_all.empty())
        std::copy(record->confidence_all.begin(), record->confidence_all.end(), confidence_all_out);
    if(amp_delta_all_out && !record->amp_delta_all.empty())
        std::copy(record->amp_delta_all.begin(), record->amp_delta_all.end(), amp_delta_all_out);
    if(power_all_out && !record->power_all.empty())
        std::copy(record->power_all.begin(), record->power_all.end(), power_all_out);
    if(velocity_all_out && !record->velocity_all.empty())
        std::copy(record->velocity_all.begin(), record->velocity_all.end(), velocity_all_out);
    if(plv_cycles_out && !record->plv_cycle.empty())
        std::copy(record->plv_cycle.begin(), record->plv_cycle.end(), plv_cycles_out);
    if(snr_cycles_out && !record->snr_cycle.empty())
        std::copy(record->snr_cycle.begin(), record->snr_cycle.end(), snr_cycles_out);

    info = record->result;

    {
        std::lock_guard<std::mutex> lock(m_queue_mutex);
        m_jobs.erase(it);
    }

    return STATUS_OK;
}

int Engine::GetStats(double& avg_ms, double& max_ms)
{
    std::lock_guard<std::mutex> lock(m_stats_mutex);
    if(m_completed_jobs == 0)
    {
        avg_ms = 0.0;
        max_ms = 0.0;
        return STATUS_OK;
    }
    avg_ms = m_total_ms / static_cast<double>(m_completed_jobs);
    max_ms = m_max_ms;
    return STATUS_OK;
}

int Engine::GetLastError(std::string& out_message) const
{
    std::lock_guard<std::mutex> lock(m_error_mutex);
    out_message = m_last_error;
    return out_message.empty() ? STATUS_OK : STATUS_ERROR;
}

void Engine::WorkerLoop()
{
    while(m_running.load())
    {
        std::shared_ptr<JobRecord> job;
        {
            std::unique_lock<std::mutex> lock(m_queue_mutex);
            m_queue_cv.wait(lock, [this]() {
                return !m_running.load() || !m_job_queue.empty();
            });

            if(!m_running.load())
                break;

            if(m_job_queue.empty())
                continue;

            auto job_id = m_job_queue.front();
            m_job_queue.pop();
            auto it = m_jobs.find(job_id);
            if(it == m_jobs.end())
                continue;
            job = it->second;
        }

        auto start_cpu = std::chrono::steady_clock::now();
        int status = (m_processor ? m_processor->Process(*job) : STATUS_NOT_INITIALISED);

        if(status != STATUS_OK || job->result.status != STATUS_READY)
        {
            job->status.store(STATUS_ERROR);
            job->result.status = STATUS_ERROR;
            std::lock_guard<std::mutex> lock_err(m_error_mutex);
            m_last_error = "GPU processing failed";
        }
        else
        {
            RunKalmanTracker(*job);
            job->status.store(STATUS_READY);
            if(job->result.elapsed_ms <= 0.0)
            {
                auto end_cpu = std::chrono::steady_clock::now();
                job->result.elapsed_ms = std::chrono::duration<double, std::milli>(end_cpu - start_cpu).count();
            }

            {
                std::lock_guard<std::mutex> lock_err(m_error_mutex);
                m_last_error.clear();
            }

            std::lock_guard<std::mutex> lock_stats(m_stats_mutex);
            m_total_ms += job->result.elapsed_ms;
            m_max_ms = std::max(m_max_ms, job->result.elapsed_ms);
            ++m_completed_jobs;
        }
    }
}

Engine& GetEngine()
{
    static Engine engine;
    return engine;
}

} // namespace gpuengine
