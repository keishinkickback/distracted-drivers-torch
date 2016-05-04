-- To create a new data file, this is what you need to do:
-- TODO Verify submission method
-- TODO Implement overcomplete crossval
-- TODO Implement conf mat for ensemble model for validation set
-- TODO Save models
-- TODO Save logs
-- TODO Move methods into other files
-- TODO decrease learning rate over time

-- Uncomment this is running with qlua
--require 'trepl'
--arg = {}
--arg[1] = '--gen_data'
require 'provider'
require 'xlua'
require 'optim'
require 'nn'
require 'provider'
c = require 'trepl.colorize'
torch.setdefaulttensortype('torch.FloatTensor')

-- Pull in requirements
-------------------------
require ('nn-aux')
require ('dd-aux')
require ('trainer')
require ('train')
require ('submission')
require ('validate')



-- Parse the command line arguments
--------------------------------------
opt = lapp[[
	--model 	(default linear_logsoftmax) 	model name
	-b,--batchSize 	(default 32) 			batch size
 	-r,--learningRate 	(default 1) 		learning rate
 	--learningRateDecay 	(default 1e-7) 		learning rate decay
	
	-s,--save 	(default "logs") 		subdirectory to save logs
	-S,--submission						generate(overwrites) submission.csv file

	-f,--n_folds	(default 3)				number of folds to use
	-g,--gen_data 				 			whether to generate data file 
	-d,--datafile 	(default p.t7) 			file name of the data provider
	-h,--height	(default 48)				height of the input images
	-w,--width	(default 64)				width of the resized images
	--L2		(default 0)					L2 norm
	--L1		(default 0)					L1 norm
	--num_train		(default -1)				Artificially reduces training set (DEBUG)

	-t,--trainAlgo	(default sgd)			training algorithm: sgd, adam, 
	--weightDecay 	(default 0.0005) 		weightDecay
	-m,--momentum 	(default 0.9) 			momentum
	--epoch_step 	(default 25) 			epoch step
	--max_epoch 	(default 300) 			maximum number of iterations

 	--backend (default cudnn) 			backend to be used nn/cudnn
 	--type (default cuda) 				cuda/float/cl
	

	-v,--validation (default 6) 			number of drivers to use in validation set
]]


if opt.backend == 'cudnn' then
	   require 'cudnn'
end





---------------------------------


---------------------------------
--           Main              --  
---------------------------------


---------------------------------




-- Generate data (and save it to file)
-----------------------------------------------
height = opt.height
width = opt.width
provider = 0

-- If generating data
if opt.gen_data then
	load_test_set = false 
	if opt.submission then
		load_test_set = true
	end
	num_train = -1
	provider = Provider("/home/tc/data/distracted-drivers/", opt.num_train, 
				height, width, load_test_set)
	provider:normalize()
	
	-- Because lua is ONE-indexed
	provider.labels = provider.labels+1

	collectgarbage()
	xprint (c.blue"Saving file...")
	torch.save(opt.datafile, provider)
end


-- Load the data
----------------------
print (c.blue"Loading data...")
provider = torch.load(opt.datafile)
provider.data = cast(provider.data)
provider.labels = cast(provider.labels)


-- Set up models/trainers
-------------------------
folds = torch.range(1,26):chunk(opt.n_folds)
-- TODO: Create a method for having multiple an overcomplete x-fold 
-- ie. drivers can appear in multiple folds, like in RF 
trainers = {}
print(c.blue '==>' ..' configuring model')
for i = 1,opt.n_folds do

	trainer = get_trainer()
	excluded_drivers = {}
	included_drivers = {}
	for j = 1,folds[i]:size(1) do
		table.insert(excluded_drivers, folds[i][j], folds[i][j])
	end
	for j = 1,26 do
		if excluded_drivers[j] == nil then
			table.insert(included_drivers, j, j)
		end
	end
	trainer.excluded_drivers = excluded_drivers
	trainer.included_drivers = included_drivers
	trainers[i] = trainer
end






-- Train / validate the model(s)
--------------------------------

for epoch = 1,opt.max_epoch do
	
	print (c.blue"Training epoch " .. epoch .. c.blue "  ---------------------------------")

	for fold = 1,opt.n_folds do
		print ("Training epoch " .. epoch .. " fold " .. fold .. "/"..opt.n_folds)

		trainer = trainers[fold]
		-- train each model one epoch
		train(trainer, trainer.excluded_drivers, epoch, true)
	end


	print (c.blue"Validation epoch " .. epoch .. c.blue "  --------------------------------")
	--[[ Validation should print out:
		- Each model's accuracy / loss on its validation set
		- Aggregated validation set accuracy / loss
		- Aggregated class accuracy/loss
		- Aggregated driver acucracy/loss
		
		* Note, should account for when a class is excluded from multiple folds
	]]
	local aggregate = torch.Tensor(provider.data:size())
	aggregate[{}] = 1
	local total_loss = 0
	local total_acc = 0
	for fold = 1,opt.n_folds do
		print ("Validating epoch " .. epoch .. " fold " .. fold  .. "/" .. opt.n_folds)
		acc, loss, n_valid = validate(trainers[fold].model, trainers[fold].excluded_drivers, false, false)
		-- TODO: use some nicer formatting
		print ("Fold " .. fold .. " (" .. string_drivers(trainers[fold].excluded_drivers).. ") \tacc = " .. acc*100 .. "\tloss = " .. loss)
		total_loss = total_loss + loss * n_valid
		total_acc = total_acc + acc * n_valid
	end
	print (c.Magenta"==>" .. " Total Validation \tacc = " ..  total_acc / provider.data_n * 100.0 .. "\t loss = " .. total_loss/provider.data_n)


	--print (c.blue"Logging epoch " .. epoch .. c.blue " ---------------")
	--[[ TODO Logging should consist of
		Each model's predictions on all data
		Saving every mode
		Confusion matrix, validation stats
	]]	

  	--save model every 10 epochs
	--[[
  	if epoch % 25 == 0 then
    	local filename = paths.concat(opt.save, 'model_' .. epoch .. '.net')
    	print('==> saving model to '..filename)
    	torch.save(filename, model:clearState())
  	end
	]]
	
	
end




