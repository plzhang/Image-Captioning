require('nn')
require('nngraph')
require('rnn')
-- require 'loadcaffe'
require('paths')
-- require "util/load_data"
local vggLSTM, parent = torch.class('ImgCap.vggLSTM', 'nn.Module')

function vggLSTM:__init(config)
    self.vocab = ld:loadVocab()
    self.ivocab = ld:loadiVocab()
    self.num_words = #self.ivocab
    self.embedding_vec = nn.LookupTable(self.num_words, config.embeddingDim)
    self.embedding_vec.weight:copy(ld:loadVocab2Emb())
    self.embed_transpose = nn.Transpose({ 1, 2 })
    self.output_transpose = nn.Transpose({ 1, 2 })


    self.visualRescale = nn.Sequential()
        :add(nn.Linear(4096, config.embeddingDim))
        :add(nn.BatchNormalization(config.embeddingDim))

    -- language model.
    local LSTMcell = nn.Sequential()
        :add(nn.LSTM(config.embeddingDim, config.embeddingDim, 60))
        :add(nn.LSTM(config.embeddingDim, config.embeddingDim, 60))
        :add(nn.Linear(config.embeddingDim, self.num_words))
    -- :add(nn.LogSoftMax())
    self.LSTM = nn.Sequencer(LSTMcell)
    collectgarbage()
end

function vggLSTM:forward(input)

    -- image nets
    self.visualFeatureRescaled = self.visualRescale:forward(input.image)

    -- vggLSTM -> LSTM -> sequencer -> recursor -> LSTMcell -> nn.LSTM, init h0 with visual feature
    self.LSTM.module.module.modules[1].userPrevOutput = self.visualFeatureRescaled

    -- LSTM
    self.text_embedding = self.embedding_vec:forward(input.text)
    self.text_embedding_transpose = self.embed_transpose:forward(self.text_embedding)

    self.LSTMout = self.LSTM:forward(self.text_embedding_transpose)
    self.output = self.output_transpose:forward(self.LSTMout)
    collectgarbage()
    return self.output
end

function vggLSTM:backward(input, grad)

    local gradT = self.output_transpose:backward(self.LSTMout, grad)


    local lstmInGrad = self.LSTM:backward(self.text_embedding_transpose, gradT)
    local lstmInGradT = self.embed_transpose:backward(self.text_embedding, lstmInGrad)
    -- backprop the rescale visual feature layer
    self.visualRescale:backward(input.image, self.LSTM.module.module.modules[1].gradPrevOutput)

    self.embedding_vec:backward(input.text, lstmInGradT)
    collectgarbage()
end

function vggLSTM:predict(imageInput, beam_search, cuda)
    local visualFeatureRescaled = self.visualRescale:forward(imageInput)
    self.LSTM.module.module.modules[1].userPrevOutput = self.visualFeatureRescaled
    --Go id is 2, Eos id is 3
    local result = {}
    local textTensor
    local textInput
    local count = 1
    if not beam_search then
        local lastWordIdx = 2

        while (lastWordIdx ~= 3) and count < 40 do
            textTensor = torch.IntTensor({ lastWordIdx })
            if cuda then
                textTensor = textTensor:cuda()
            end
            if count ~= 1 then
                -- print("lllll_1")
                -- print("User prev output size")
                -- print(self.LSTM.module.module.modules[1].userPrevOutput:size())
                -- print("LSTM hidden size")
                -- print(self.prevHidden_2:size())
                self.LSTM.module.module.modules[1].userPrevOutput = self.prevHidden_1
                self.LSTM.module.module.modules[2].userPrevOutput = self.prevHidden_2
                -- print("lllll_2")
                self.LSTM.module.module.modules[1].userPrevCell = self.prevCell_1
                -- print("lllll_3")
                self.LSTM.module.module.modules[2].userPrevCell = self.prevCell_2
            end

            -- if count == 1 then
            --     self.LSTM.module.module.modules[1].cell:zero()
            --     self.LSTM.module.module.modules[2].
            -- end 
            -- print(textTensor:type())
            -- print(textTensor)

            textInput = self.embedding_vec:forward(textTensor)
            -- print(textInput:size())
            self.LSTMoutput = self.LSTM:forward(textInput)
            -- print(self.LSTMout:size())
            self.prevCell_1 = self.LSTM.module.module.modules[1].cell
            self.prevHidden_1 = self.LSTM.module.module.modules[1].output
            -- print(self.prevCell_1)
            self.prevCell_2 = self.LSTM.module.module.modules[2].cell
            self.prevHidden_2 = self.LSTM.module.module.modules[2].output
            -- print(self.prevCell_2)
            val, idx = torch.max(self.LSTMoutput:float(), 2)
            lastWordIdx = torch.totable(idx)[1][1]
            print(lastWordIdx .. ' ' .. self.ivocab[lastWordIdx])
            table.insert(result, lastWordIdx)
            count = count + 1
        end
    end

    return self:convertWordIdxToSentence(result)
end

function vggLSTM:convertWordIdxToSentence(tokenIndices)
    local sentence = {}
    for i = 1, #tokenIndices do
        local word = self.ivocab[tokenIndices[i]]
        table.insert(sentence, word)
    end
    return table.concat(sentence, " ")
end


function vggLSTM:parameters()
    local modules = nn.Parallel()
    modules:add(self.embedding_vec):add(self.visualRescale):add(self.LSTM)
    return modules:parameters()
end

function vggLSTM:cuda()
    self.embedding_vec:cuda()

    self.embed_transpose:cuda()
    self.output_transpose:cuda()

    -- self.imageModel:cuda()
    self.visualRescale:cuda()

    self.LSTM:cuda()
end

return vggLSTM

