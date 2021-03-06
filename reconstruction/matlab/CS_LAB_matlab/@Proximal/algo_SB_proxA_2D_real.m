function [imageCha, ssim_map, metrics] = algo_SB_proxA_2D_real( obj,input )
% 2D variant of SB
% based on Goldstein and Oshers paper on Split Bregman
%
% input:
% obj           CS reconstruction object (holding all parameters)
% input         struct containing recon parameters and image
%
% output:
% imageCha      reconstructed channel individual image
% ssim_map      structural similarity map
% metrics       evaluation metrics 
%
% (c) Marc Fischer, Thomas Kuestner, May 2015
% -------------------------------------------------------------------------

%%
timer_proxA = tic;

%% variables:
% internal flags
flag_wavetree = true;
flag_fast = true;
flag_extendImage = true;

% internal variables:
L = 1;
t_old = 1;
NLTV_struct.kernelratio = 3;
NLTV_struct.windowratio = 6;
NLTV_struct.nThreads = 1;  % mind this option if used with -singleCompThread on BWCluster
itrNLTV = obj.maxitr - 20;
% chambolle tv:
parsin.MAXITER=100; parsin.tv='iso'; % 'iso' or 'l1'

% from obj:
% maxitr = obj.maxitr;
maxitr = obj.iNINNER;
% maxitrOUTER = obj.maxitrOUTER;
maxitrOUTER = obj.iNOUTER;
maxitrINNER = ceil( maxitr / maxitrOUTER );
% n1 = obj.measPara.dim(1);
% n2 = obj.measPara.dim(2);
n1 = input.n1;
n2 = input.n2;
% nSlices = obj.measPara.dim(3);
nCha = obj.measPara.dim(5);
lambdaWave = obj.lambda;
lambdaTV = obj.lambdaTV;
lambdaGroup = obj.lambdaGroup;
NLTV_struct.filterstrength = obj.lambdaNLTV_h; % 0.03 % converted from NLTV h = 0.01 %old: used: 3e-10
lambdaNLTV = obj.lambdaNLTV;
lambdaNLTV_h = obj.lambdaNLTV_h;
mue = obj.mue;
regularizerWeights = obj.regularizerWeights;
flagTV = obj.flagTV;
flagTV_iso = obj.flagTV_iso;
flagWave = obj.flagWave;
flagGroup = obj.flagGroup;
flagNLTV = obj.flagNLTV;
flagSBNLTV = obj.flagSBNLTV;
waveletStages = obj.trafo.waveletStages;
waveletFilterName_l1 = obj.trafo.waveletFilterName_l1;
waveletFilterName_l12 = obj.trafo.waveletFilterName_l12;

% from input:
b=input.b;
mask = input.mask;
G_prox = input.G_prox;
Gt_prox = input.Gt_prox;
groupnorm_index = input.groupnorm_index;
waveS_l1 = input.waveS_l1;
waveS_l12 = input.waveS_l12;
waveS_l12proxA = input.waveS_l12proxA;
proxA_extend_y = waveS_l12proxA(waveletStages+2,1) - waveS_l12(waveletStages+2,1);
proxA_extend_x = waveS_l12proxA(waveletStages+2,2) - waveS_l12(waveletStages+2,2);
x_proxA = cell(1,nCha);

% im_ref = input.im_ref;
% im_ref_full = zeros(n1,n2);
% for j = 1:nCha
%     im_ref_full = im_ref_full + abs(im_ref{1,j}).^2;
% end;
% im_ref_full = sqrt(im_ref_full);
clear input

% initialize cells/vectors
for j=1:nCha
    FTb{1,j} = real(iFFT2D(b{1,j}));
    % y{1,j} = real(FTb{1,j});
    % y{1,j+nCha} = imag(FTb{1,j});
end;
% starting point:
x = FTb; % (x0 = FTb)
rhs = FTb; % different start (x0 = F^-1 K^-1 F FTb); %used atm
b_outer = b;
% rhs: right hand side

x_wave =  cell(1,nCha);
x_g_proxA = x_wave;
x_g_helper = cell(2,nCha);
x_wave_helper = rhs;
v_wave = rhs;
d_wave = rhs;
x_tv = rhs;
v_tv = rhs;
d_tv = rhs;
x_group = rhs;
v_group = rhs;
d_group = rhs;
x_nltv = rhs;
v_nltv = rhs;
d_nltv = rhs;
K_inv = rhs;
for j = 1:nCha
    x_wave{1,j} = 0;
    v_wave{1,j} = 0;
    d_wave{1,j} = 0;
    x_tv{1,j} = zeros(n1,n2);
    v_tv{1,j} = 0;
    d_tv{1,j} = 0;
    x_group{1,j} = 0;
    v_group{1,j} = 0;
    d_group{1,j} = 0;
    x_nltv{1,j} = 0;
    v_nltv{1,j} = 0;
    d_nltv{1,j} = 0;
end;

%% MAD dependent lambdas:
flag_MAD = true;
if flag_MAD
    x_wavedec = cell(1,nCha);
    threshold = zeros(1:nCha);
    for j=1:nCha % 2*nCha
        x_wavedec{1,j} = wavedec2(x{1,j},waveletStages,waveletFilterName_l1); % atm only based on l1-daubechie
        x_wave_fine_scale = size(x_wavedec{1,j},2) - (3*waveS_l1(waveletStages+1,1)*waveS_l1(waveletStages+1,2));
        threshold(j) = mad(x_wavedec{1,j}(x_wave_fine_scale:end),1);
    end;
    clear x_wavedec
else
    threshold(1:nCha) = 1;
end;

threshold_wave(j) = lambdaWave * threshold(j) * 2/L;
threshold_TV(j) = lambdaTV * threshold(j) * 2/L;
threshold_group(j) = lambdaGroup * threshold(j) * 2/L;
threshold_NLTV(j) = lambdaNLTV; % * threshold(j) * 2/L;
threshold_NLTV_h(j) = lambdaNLTV_h; %*threshold(j); % adjust carefully or NLTV won't find a solution. lambdaNLTV_h should be < 0.01

%% initialize metrics:
itr = 0;
metrics.xtime(itr+1)= 0;
% [metrics, ssim_map{1,1}] = get_metrics_itr( im_ref, im_ref_full, x, itr, maxitr, nCha, n1, n2, metrics, obj.K_1, obj.K_2, obj.W_size, obj.W_sigma );
ssim_map = [];

%% recon
% inverse for x - step:
for j = 1:nCha
    K_inv{1,j} = 1./(mue*mask + (flagWave*regularizerWeights(1) + flagTV*regularizerWeights(2) +  flagGroup*regularizerWeights(3))*ones(n1,n2)); % flagNLTV changes K_inv -> in separate
end;

dispProgress('Proximal Average', 0, maxitrOUTER*maxitrINNER);
itr = 0;
for itrOUTER = 1:maxitrOUTER  % total iter counter
    for itrINNER = 1:maxitrINNER
        
        %% x - step
        if itr > 1 % for i = 1 already set (x{1,j} = FTb{1,j})
            for j = 1:nCha
                % rhs part:
                if flagWave
                    x_wave{1,j} = waverec2((v_wave{1,j} - d_wave{1,j}),waveS_l1,waveletFilterName_l1); end;
                if flagTV
                    x_tv{1,j} = v_tv{1,j} - d_tv{1,j}; end;
                if flagGroup
                    x_g_proxA{1,j} = waverec2((v_group{1,j} - d_group{1,j}),waveS_l12proxA,waveletFilterName_l12);
                    x_group{1,j} =  x_g_proxA{1,j}(1:end-proxA_extend_y,1:end-proxA_extend_x);
                end;
                if flagNLTV
                    if itr == itrNLTV
                        K_inv{1,j} = 1./(mue*mask + (flagWave*regularizerWeights(1) + flagTV*regularizerWeights(2) +  flagGroup*regularizerWeights(3) + flagNLTV*regularizerWeights(4))*ones(n1,n2));
                        x_nltv{1,j} = x{1,j};
                    elseif itr >= itrNLTV
                        x_nltv{1,j} = v_nltv{1,j} - d_nltv{1,j};
                    end;
                end;
                rhs{1,j} = mue*FTb{1,j} + ( flagWave*regularizerWeights(1).*(x_wave{1,j}) + flagTV*regularizerWeights(2).*(x_tv{1,j}) + flagGroup*regularizerWeights(3).*(x_group{1,j}) + flagNLTV*regularizerWeights(4).*(x_nltv{1,j}));
                x{1,j} = real(iFFT2D(K_inv{1,j}.*FFT2D(rhs{1,j})));
            end;
        end;
        
        %% auxiliary variables:
        %% l1-Wavelet
        if flagWave
            for j = 1:nCha
                x_wave_helper{1,j} = wavedec2(x{1,j},waveletStages,waveletFilterName_l1);
                v_wave{1,j} = softthresh_real((x_wave_helper{1,j} + d_wave{1,j}),threshold_wave(j));
                d_wave{1,j} = d_wave{1,j} + x_wave_helper{1,j} - v_wave{1,j};
            end;
        end;
        
        %% TV:
        if flagTV
            if ~flagTV_iso
                for j = 1:nCha
                    v_tv{1,j} = MTV_2D((x{1,j} + d_tv{1,j}), threshold_TV(j), n1, n2);
                end;
            else
                for j = 1:nCha
                    if (itr < 2)
                        [v_tv{1,j}, P]=denoise_TV_One((x{1,j} + d_tv{1,j}), threshold_TV(j),-inf,inf,[],parsin);
                    else
                        [v_tv{1,j}, P]=denoise_TV_One((x{1,j} + d_tv{1,j}), threshold_TV(j),-inf,inf,P,parsin);
                    end;
                end;
            end;
            d_tv{1,j} = d_tv{1,j} + x{1,j} - v_tv{1,j};
        end;
        
        %% NLTV
        if flagNLTV
            if itr >= itrNLTV
                if flagSBNLTV
                    for j = 1:nCha
                        v_nltv{1,j} = SB_NLTVfunc_slim_rescale( (x{1,j} + d_nltv{1,j}),n1,n2, threshold_NLTV(j), threshold_NLTV_h(j) );
                    end;
                else
                    for j = 1:nCha
                        % if mod(itr,5) == 0 || itr == 1
                        v_nltv{1,j} = NLMF((x{1,j} + d_nltv{1,j}),NLTV_struct);
                        v_nltv{1,j} = (L.*(x{1,j} + d_nltv{1,j}) + 2*threshold_NLTV(j)*v_nltv{1,j})./(L+2*threshold_NLTV(j));
                        % end;
                    end;
                end;
                d_nltv{1,j} = d_nltv{1,j} + x{1,j} - v_nltv{1,j};
            else
                v_nltv{1,j} = 0;
                d_nltv{1,j} = 0;
            end;
            
        end;
        
        %% l12-Wavelet
        if flagGroup
            for j = 1:nCha
                if flag_extendImage
                    x_proxA{1,j} = extend_image(x{1,j}, waveS_l12proxA, waveletStages, proxA_extend_y, proxA_extend_x);
                    x_g_helper{1,j} = wavedec2(x_proxA{1,j},waveletStages,waveletFilterName_l12) + d_group{1,j};
                else
                    x_g_helper{1,j} = wavedec2(x{1,j},waveletStages,waveletFilterName_l12) + d_group{1,j};
                end;
                
                if flag_wavetree
                    x_g_helper{2,j} = (G_prox*x_g_helper{1,j}')';
                else
                    x_g_helper{2,j} = zeros(1,size(x_g_helper{1,j},2));
                end;
            end;
            
            % softthresh_proxA_cha returns cell! hence (1,:) assignement
            v_group(1,:) = softthresh_proxA_cha(x_g_helper,threshold_group(j),nCha,waveS_l12proxA,groupnorm_index);
            
            for j = 1:nCha
                d_group{1,j} = d_group{1,j} + x_g_helper{1,j} - v_group{1,j};
            end;
        end;
        
        %% metrics of current itr:
        itr = itr + 1;
%         disp(itr);
        dispProgress('Proximal Average', itr/(maxitrOUTER*maxitrINNER));
        
        metrics.xtime(itr+1)= toc(timer_proxA);
%         [metrics, ssim_map{1,2}] = get_metrics_itr( im_ref, im_ref_full, x, itr, maxitr, nCha, n1, n2, metrics, obj.K_1, obj.K_2, obj.W_size, obj.W_sigma );
        
        if itr >= maxitr break; end;
    end;
    if itr >= maxitr break; end;
    for j=1:nCha
        b_outer{1,j} = b_outer{1,j} + b{1,j} - FFT2D_mask(x{1,j},mask);
        FTb{1,j} = real(iFFT2D(b_outer{1,j}));
    end;
end;
dispProgress('Proximal Average', 'Close');

imageCha = x;
for j = 1:nCha
    imageCha{1,j} = turn_image( imageCha{1,j} );
end;
% for j = 1:nCha+1
%     ssim_map{1,1}{1,j} = turn_image( ssim_map{1,1}{1,j} );
%     ssim_map{1,2}{1,j} = turn_image( ssim_map{1,2}{1,j} );
% end;

end