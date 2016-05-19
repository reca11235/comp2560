% % Copyright (C) 2014 LEAR, Inria Grenoble, France
% 
% Permission is hereby granted, free of charge, to any person obtaining
% a copy of this software and associated documentation files (the
% "Software"), to deal in the Software without restriction, including
% without limitation the rights to use, copy, modify, merge, publish,
% distribute, sublicense, and/or sell copies of the Software, and to
% permit persons to whom the Software is furnished to do so, subject to
% the following conditions:
% 
% The above copyright notice and this permission notice shall be
% included in all copies or substantial portions of the Software.
% 
% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
% EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
% MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
% NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
% LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
% OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
% WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

%%
% If you use this code, please cite: 
% @INPROCEEDINGS{cherian14, 
% author={Cherian, A. and Mairal, J. and Alahari, K. and Schmid, C.}, 
% booktitle={IEEE Conference on Computer Vision and Pattern Recognition}, 
% title={Mixing Body-Part Sequences for Human Pose Estimation}, 
% year={2014}
% }
% 
% demo code main file to run.
% for bugs contact anoop.cherian@inria.fr
%
function [out_tab, pix_error, detected_pose_seqs, gt_all] = demo(stats_path)
warning 'off';
startup(); % set some paths

% configure. See the function for details. You need to set the cache and
% the sequence paths in the config.
config = set_algo_parameters();
% Overriding so that I don't need my own config :P
config.data_store_path = config.mpii_data_store_path;
config.data_path = config.mpii_data_path;
config.data_flow_path = config.mpii_data_flow_path;

% load the bodypart model learned using Yang and Ramanan framework.
model_l = load('./data/FLIC_model.mat');% the 13part FLIC human pose model.
model = model_l.model;

% get the dataset and gt annotations
% load mpii test seqs in 13 part version
mpii_test_seqs = get_mpii_cooking(...
    config.mpii_dest_path, config.cache_path, config.mpii_trans_spec);
mpii_data = translate_mpii_seqs(mpii_test_seqs, config.mpii_data_path);

% process each sequence, here we show only for seq15 available in the
% dataset folder. 
seqs = dir(config.mpii_data_path); seqs = seqs(3:end);
dps_parsave = cell([1 length(seqs)]);
all_detections = []; gt_all = []; mov = 1;

% for every sequence in the selected_seqs folder (with the dataset)
parfor s=1:length(seqs)
    fprintf('working on sequence %s\n', seqs(s).name);

    % read the frames and store the respective groundtruth annotations.
    seq_dir = [config.data_path seqs(s).name '/']; %#ok<PFBNS>
    frames = dir([seq_dir '/*.png']);
    gt = get_groundtruth_for_seq(frames, mpii_data);% extract gt annotations for the frames in seq
    gt_all = [gt_all, gt]; % used for full evaluation.

    % now we are ready to compute the part sequences and recombination! 
    detected_poses = do_the_thing(config, seqs(s).name, seq_dir, model);
    
    % fill in some structure for the complete evaluation
    dps_struct = struct('seq', {}, 'filename', {}, 'frame', {}, 'bestpose',{});
    for i=1:length(frames)
        dps_struct(i).seq = seqs(s).name;
        dps_struct(i).filename = frames(i).name;
        frame_match = regexp(frames(i).name, '-(?<frame_no>\d+)\.png$', 'names');
        assert(numel(frame_match) == 1);
        dps_struct(i).frame = str2double(frame_match.frame_no);

        % if we could find a pose sequence path
        if ~isempty(detected_poses)            
            dps_struct(i).bestpose = detected_poses(i,:);            
        else
            dps_struct(i).bestpose = [];
        end
    end
    dps_parsave{s} = dps_struct;
    %show_pose_sequence(seq_dir, frames, detected_poses);
end

detected_pose_type = struct('seq', {}, 'filename', {}, 'frame', {}, 'bestpose',{});
detected_pose_seqs = repmat(detected_pose_type, [1,1,1]);
for s=1:length(seqs)
    some_struct = dps_parsave{s};
    % For some reason this manual assignment works, but doing
    % detected_pose_seqs(mov, s, :) doesn't; it seems that the manual
    % assignment can expand the struct array but the slicing one cannot.
    for i=1:length(some_struct)
        detected_pose_seqs(mov, s, i) = some_struct(i);
    end
end

%
% evaluate the sequences for pixel error
fprintf('evaluating pixel error\n');
thresholds = config.eval_pix_thresholds;
pix_error = zeros(length(config.eval_pix_thresholds), 11);
for i=1:length(config.eval_pix_thresholds) % can be converted to parfor if there are lots of these
    fprintf('WARNING: Threshold has been silently decreased to account for image resizing!\n');
    thresh = thresholds(i) * 0.35; % XXX: I'm making the threshold much smaller to account for rescaling of input images
    pix_error(i, :) = evaluate_pose_seqs(detected_pose_seqs, gt_all, thresh);
end

fprintf('flattening into other format\n');
[flat_dets, flat_gts] = flatten_to_cells(detected_pose_seqs, gt_all);
save(fullfile(config.cache_path, 'flat_preds.mat'), 'flat_dets', 'flat_gts');
fprintf('evaluating PCP\n');
limbs = struct('indices', ...
    {[7 9], [9 11], [2 4], [4 6]}, ...
    'names', ...
    {'ruarm', 'rfarm', 'luarm', 'lfarm'});
pcps = pcp_new(flat_dets, flat_gts, {limbs.indices});
pcp_t = table({limbs.names}', pcps', 'VariableNames', {'Limb', 'PCP'});
disp(pcp_t);

out_tab = table(...
    thresholds', ...
    mean(pix_error(:, [2, 7]), 2), ...
    mean(pix_error(:, [4, 9]), 2), ...
    mean(pix_error(:, [6, 11]), 2), ...
    'VariableNames', {'Threshold', 'Shoulder', 'Elbow', 'Wrist'});

% It would be nice to have head error, but PIW defines "head" differently
% to FLIC, so we have to stick with shoulders, elbows and wrists :(

if nargin == 0
    fprintf('No output file specified, writing stats to console\n');
    disp(out_tab);
else
    fprintf(['Writing stats to ' stats_path '\n']);
    writetable(out_tab, stats_path);
end
end

function detected_poses = do_the_thing(config, seqs_name, seq_dir, model)
try        
    load([config.data_store_path 'detected_poses_' seqs_name], 'detected_poses'); 
catch
    detected_poses = EstimatePosesInVideo(seq_dir, model, 1, config);   
    save([config.data_store_path '/detected_poses_' seqs_name], 'detected_poses');
end
end
