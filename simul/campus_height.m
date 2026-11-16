
clear; clc; close all;

%% 1. DEM 불러오기
[Z, R] = readgeoraster("37608.img");
Z = double(Z);

%% 2. 국민대학교 좌표
lat = 37.6109;
lon = 126.9970;

crs = projcrs(5179);
[xKMU, yKMU] = projfwd(crs, lat, lon);

%% 3. DEM 범위 확인
disp(R.XWorldLimits)
disp(R.YWorldLimits)

fprintf("국민대학교 X: %.2f\n", xKMU);
fprintf("국민대학교 Y: %.2f\n", yKMU);

%% 4. DEM 시각화
figure;

imagesc(R.XWorldLimits, R.YWorldLimits, flipud(Z));
set(gca, 'YDir', 'normal');

axis equal;
colormap(turbo);
colorbar;
hold on;

%% 5. 국민대학교 위치 표시
plot(xKMU, yKMU, 'rp', ...
    'MarkerSize', 15, ...
    'MarkerFaceColor', 'r');

text(xKMU-1500, yKMU+500, ...
    'Kookmin University', ...
    'Color', 'red', ...
    'FontWeight', 'bold');

%% 6. 캠퍼스 주변 2km 범위
xlim([xKMU-1000, xKMU+1000]);
ylim([yKMU-1000, yKMU+1000]);

title("Kookmin University - DEM");
xlabel("Easting (m)");
ylabel("Northing (m)");
grid on;
