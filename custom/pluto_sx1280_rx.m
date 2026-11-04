% Receive SX1280 2.4 GHz LoRa packets with PlutoSDR and decode with LoRaPHY.
% The T3S3 transmitter and this script must use identical LoRa parameters.
% This assumes the packet sync word/interleaving are compatible with LoRaPHY.

script_dir = fileparts(mfilename('fullpath'));
addpath(fileparts(script_dir));

radio_id = 'usb:0';       % Replace with the ID reported by findPlutoRadio.
rf_freq = 2.4e9;          % Match the T3S3 SX1280 transmitter below.
sf = 7;
bw = 203.125e3;           % SX1280 LoRa bandwidth option (kHz value in Hz).
fs = 4 * bw;              % 812.5 kS/s; aligns LoRaPHY's discrete chirp samples.
rx_frame_samples = 65536;
listen_seconds = 60;
save_iq = false;
iq_file = fullfile(script_dir, 'sx1280_rx_capture.mat');

phy = LoRaPHY(rf_freq, sf, bw, fs);
phy.has_header = 1;       % Explicit header.
phy.cr = 1;               % CR 4/5; header also carries the CR value.
phy.crc = 1;
phy.preamble_len = 8;

rx = sdrrx('Pluto', ...
    'RadioID', radio_id, ...
    'CenterFrequency', rf_freq, ...
    'BasebandSampleRate', fs, ...
    'SamplesPerFrame', rx_frame_samples, ...
    'OutputDataType', 'double', ...
    'GainSource', 'AGC Slow Attack');
rx_cleanup = onCleanup(@() release(rx));
disp(info(rx));

fprintf('Listening for SX1280 LoRa at %.3f MHz, SF%d, BW %.3f kHz, fs %.1f MS/s.\n', ...
    rf_freq/1e6, sf, bw/1e3, fs/1e6);
fprintf('Start T3S3 transmission now. Listening for %d seconds.\n', listen_seconds);

rx_buffer = complex(zeros(0, 1));
capture = complex(zeros(0, 1));
timer = tic;
while toc(timer) < listen_seconds
    frame = rx();
    frame = double(frame(:));
    rx_buffer = [rx_buffer; frame]; %#ok<AGROW>
    if save_iq
        capture = [capture; frame]; %#ok<AGROW>
    end

    % Leave headroom so packets crossing frame boundaries remain available.
    if numel(rx_buffer) < 3 * rx_frame_samples
        continue;
    end

    try
        % demodulate warns when no preamble is present; hide only that idle warning.
        evalc('[rx_symbols, ~, rx_sync] = phy.demodulate(rx_buffer);'); %#ok<NASGU>
    catch ME
        warning('LoRaPHY:DemodulateFailed', '%s', ME.message);
        rx_symbols = [];
    end

    if ~isempty(rx_symbols)
        try
            [decoded, checksum] = phy.decode(rx_symbols);
        catch ME
            warning('LoRaPHY:DecodeFailed', '%s', ME.message);
            decoded = [];
            checksum = [];
        end

        for packet_idx = 1:size(decoded, 2)
            payload_len = phy.payload_len;
            if payload_len < 1 || size(decoded, 1) < payload_len + 2 || isempty(checksum)
                continue;
            end

            packet = uint8(decoded(:, packet_idx));
            packet_crc = packet(payload_len+1:payload_len+2);
            expected_crc = uint8(checksum(:, min(packet_idx, size(checksum, 2))));
            if ~isequal(packet_crc(:), expected_crc(:))
                fprintf('Packet detected, but CRC check failed.\n');
                continue;
            end

            payload = packet(1:payload_len);
            try
                message = native2unicode(payload(:).', 'UTF-8');
                fprintf('[CRC OK] %d bytes: %s\n', numel(payload), message);
            catch
                fprintf('[CRC OK] Received %d bytes (not valid UTF-8 text):\n', numel(payload));
                disp(payload(:).');
            end
        end
    end

    % Keep a tail for the next receive window, including packets at boundaries.
    keep = min(numel(rx_buffer), 2 * rx_frame_samples);
    rx_buffer = rx_buffer(end-keep+1:end);
end

release(rx);
if save_iq
    save(iq_file, 'capture', 'rf_freq', 'sf', 'bw', 'fs', '-v7.3');
    fprintf('Raw IQ capture saved to %s\n', iq_file);
end
fprintf('Listening complete.\n');
