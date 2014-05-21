-----------------------------------------------------------------------
--[[ View ]]-- 
-- Allows for efficiently communicating tensors between Models.
-- Exists at the output of a Model or a DataSource
------------------------------------------------------------------------
local View, parent = torch.class("dp.View")
View.isView = true

function View:__init()
   -- caches
   self._tensors = {}
   self._warn = false
end

---------------------- FORWARD -----------------------

-- View is a string. Acceptable views include:
-- b, bf, bhwc, chwb, bchw, bsf, bfs, etc.
function View:forward(view, inputORtype)
   assert(torch.type(view) == 'string', "Expecting string at arg 1")
   if torch.type(inputORtype) == 'string' then
      return self:forwardGet(view, inputORtype)
   end
   return self:forwardPut(view, inputORtype)
end

-- This method should be called by a maximum of one input Model.
-- It is assumed that any input Tensor to forward is represented as
-- the most expanded size of the orignal data. For example, an image
-- batch would be forwarded with its 4 dimensions, and never with 
-- collapses dimensions (2D). 
function View:forwardPut(view, input)
   -- store input for later use
   self._dim = #view
   if input:dim() ~= self._dim then
      error("view has more axes than input has dims", 3)
   end
   self._view = view
   self._input = input
   -- since this method is called only once at beginning of batch,
   -- we reinitialize gradOutputs and tensors cache:
   self._type = torch.typename(input)
   self._tensors = {[view] = {[self._type] = input}}
   self._gradOutputs = {}
   if not self._modules then
      self._modules = {
         [view] = {nn.Identity(), {[self._type] = nn.Identity()}}
      }
   end
end
   
-- This method could be called from multiple output Models
function View:forwardGet(view, tensor_type)
   -- retrieve a viewTable
   local viewTable = self._tensors[view]
   if not viewTable then
      -- no viewTable: get tensor from module
      return self:tensorFromModule(view, tensor_type)
   else
      local tensor = viewTable[tensor_type]
      if not tensor then
         return self:tensorFromModule(view, tensor_type)
      end
      return tensor
   end
end

function View:tensorFromModule(view, tensor_type)
   local moduleTable = self._modules[view]
   if not moduleTable then
      -- no moduleTable: build a module
      local modula = self[view](self)
      local copy = nn.Copy(torch.typename(self._input), tensor_type)
      self._modules[view] = {modula, {[tensor_type] = copy}}
      local tensor = modula:forward(self._input)
      local viewTable = {[tensor_type] = tensor}
      tensor = copy:forward(tensor)
      viewTable[tensor_type] = tensor
      self._tensors[view] = viewTable
      return tensor
   end
   local modula, copyTable = unpack(moduleTable)
   local tensor = modula:forward(self._input)
   local viewTable = {[tensor_type] = tensor}
   local copy = copyTable[tensor_type]
   if not copy then
      -- no copy : build copy module
      copy = nn.Copy(torch.typename(self._input), tensor_type)
      copyTable[tensor_type] = copy
   end
   tensor = copy:forward(tensor)
   viewTable[tensor_type] = tensor
   self._tensors[view] = viewTable
   return tensor
end

------------------------ BACKWARD -------------------------

function View:backward(view, gradOutputORtype)
   assert(torch.type(view) == 'string', "Expecting string at arg 1")
   if torch.type(gradOutputORtype) == 'string' then
      return self:backwardGet(view, gradOutputORtype)
   end
   return self:backwardPut(view, gradOutputORtype)
end

-- This method could be called from multiple output Models
function View:backwardPut(view, gradOutput)
   -- store gradOutput in list
   table.insert(self._gradOutputs, {view, gradOutput})
end

-- This method should be called by a maximum of one input Model.
-- In the case of multiple output models having called backwardPut, 
-- the different gradInputs must be accumulated (sum grads).
function View:backwardGet(view, tensor_type)
   if (torch.typename(self._input) ~= tensor_type) then
      error"backwardGet sould be called with the same type as self._data"
   end
   local view, gradOutput, gradInput
   
   -- optimization : one-to-one backward
   if #self._gradOutputs == 1 then
      view, gradOutput = unpack(self._gradOutputs[1])
      tensor_type = torch.typename(gradOutput)
      local moduleTable = self._modules[view]
      assert(moduleTable, "backward must follow a forward")
      local modula, copyTable = unpack(moduleTable)
      assert(copyTable, "backward must follow a forward")
      gradInput = copyTable[tensor_type]:backward(nil, gradOutput)
      gradInput = modula:backward(nil, gradInput)
      return gradInput
   end
   
   -- slower : many-to-one backward
   if not self._gradInput then
      self._gradInput = self._input:clone()
   end
   for i, gradOutputTable in ipairs(self._gradOutputs) do
      view, gradOutput = unpack(gradOutputTable)
      local moduleTable = self._modules[view]
      assert(moduleTable, "backward must follow a forward")
      local modula, copyTable = unpack(moduleTable)
      assert(copyTable, "backward must follow a forward")
      tensor_type = torch.typename(gradOutput)
      gradInput = copyTable[tensor_type]:backward(nil, gradOutput)
      gradInput = modula:backward(nil, gradInput)
      -- accumulate
      if i == 1 then
         self._gradInput:copy(gradInput)
      else
         self._gradInput:add(gradInput)
      end
   end
   return self._gradInput
end

---------------------- VIEWS ---------------------------

-- batch feature
function View:bf()
   local view, dim = self._view, self._dim
   local b_pos = self:findAxis('b', view)
   -- was b
   if dim == 1 then
      if self._warn then
         print("View:feature Warning: provided data has one "..
               "dim. Assuming dim is 'b' axis with feature size of 1")
      end
      return nn.Reshape(1)
   end
   -- was b...
   local modula
   if b_pos ~= 1 then
      modula = nn.Transpose({1, b_pos})
   end
   if dim > 2 then
      local transpose = modula
      local reshape = nn.Reshape(self:sampleSize(b_pos))
      if transpose then
         modula = nn.Sequential()
         modula:add(transpose)
         modula:add(reshape)
      else
         modula = reshape
      end
   end
   return modula or nn.Identity()
end

---------------------- MISC ----------------------------

function View:findAxis(axis_char, view)
   view = view or self._view
   local axis_pos = view:find(axis_char)
   if not axis_pos then
      error("Provided view '"..view.."' has no axis '"..axis_char.."'", 2)
   end
   return axis_pos
end

function View:sampleSize(b_pos, view, data)
   b_pos = b_pos or self:findAxis('b', view)
   data = data or self._input
   local size = 1
   for i=1,data:dim() do
      if i ~= b_pos then
         size = size * self._input:size(i)
      end
   end
   return size
end

-- Returns number of samples
function View:nSample(b_pos)
   b_pos = b_pos or self:findAxis('b')
   return self._input:size(b_pos)
end

function View:pairs()
   return pairs{self}
end

-- When dt is provided, reuse its data (a torch.Tensor).
-- config is a table of key-values overwriting the clones constructor's
function View:index(v, indices)
   assert(self._input:type() ~= 'torch.CudaTensor', 
      "View:index doesn't work with torch.CudaTensors.")
   local b_pos = self:findAxis('b')
   local data
   if indices and v then
      if torch.type(v) ~= torch.type(self) then
         error("Expecting "..torch.type(self).." at arg 1 "..
               "got "..torch.type(v).." instead")
      end
      data = v._input
      -- dont use datatensor if cuda (index not in cutorch yet)
      if data:type() ~= 'torch.CudaTensor' then
         torch.Tensor.index(data, self._input, b_pos, indices)
      else
         data = self._data:index(b_pos, indices)
      end
      assert(self._view == v._view, "Expecting arg 1 to have same view")
      v:forward(self._view, data)
      return v
   end
   indices = indices or v
   data = self._input:index(b_pos, indices)
   v = torch.protoClone(self)
   v:forward(self._view, data)
   return v
end

--Returns a sub-datatensor narrowed on the batch dimension
function View:sub(start, stop, new)
   local b_pos = self:findAxis('b')
   local data = self._input:narrow(b_pos, start, stop-start+1)
   local v
   if new then
      v = torch.protoClone(self)
   else
      v = self._v
      if not v then
         v = torch.protoClone(self)
         self._v = v
      end
   end
   assert(self._view == v._view, "Expecting arg 1 to have same view")
   v:forward(self._view, data)
   return v
end

function View:type(type)
   error"Not Implemented"
   self._input = self._input:type(type)
end

-- a generic function for transposing images
function View:transpose(new_view)
   local view = _.split(self._view)
   local transpositions = {}
   for i=1,#new_view do
      local j = _.indexOf(view, new_view:sub(i,i))
      if i ~= j then
         local char = view[i]
         view[i] = view[j]
         view[j] = char
         table.insert(transpositions, {j, i})
      end
   end
   return nn.Transpose(unpack(transpositions))
end
