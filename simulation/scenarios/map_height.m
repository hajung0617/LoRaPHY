
%% DEM 불러오기
clear; clc; close all;

% DEM 읽기
projectRoot = fileparts(fileparts(mfilename("fullpath")));
demFile = fullfile(projectRoot,"data","simulation","raw","37608.img");
[Z, R] = readgeoraster(demFile);

Z = double(Z);

% DEM 정보 확인
info = georasterinfo(demFile);
disp(info);

% DEM 시각화
figure;
mapshow(Z, R, DisplayType="surface");
colorbar;
title("DEM Elevation - 37608");
xlabel("Easting (m)");
ylabel("Northing (m)");
