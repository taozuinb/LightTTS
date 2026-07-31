# import faulthandler
# faulthandler.enable()
import os
import numpy as np
import multiprocessing as mp
import threading
from multiprocessing import shared_memory
from light_tts.utils.log_utils import init_logger
from filelock import FileLock
from collections import OrderedDict

logger = init_logger(__name__)


class SharedArray:
    def __init__(self, name, shape, dtype):
        dtype_byte_num = np.array([1], dtype=dtype).dtype.itemsize
        dest_size = np.prod(shape) * dtype_byte_num
        try:
            shm = shared_memory.SharedMemory(name=name, create=True, size=dest_size)
            logger.info(f"create shm {name}")
        except Exception as e:
            shm = shared_memory.SharedMemory(name=name, create=False, size=dest_size)
            logger.info(f"link shm {name} error {str(e)}")
        
        if shm.size != dest_size:
            logger.info(f"size not same, unlink shm {name} and create again")
            shm.unlink()
            shm.close()
            try:
                shm = shared_memory.SharedMemory(name=name, create=True, size=dest_size)
                logger.info(f"create shm {name}")
            except Exception as e:
                shm = shared_memory.SharedMemory(name=name, create=False, size=dest_size)
                logger.info(f"link shm {name} error {str(e)}")

        self.shm = shm  # SharedMemory 对象一定要被持有，否则会被释放
        self.arr = np.ndarray(shape, dtype=dtype, buffer=self.shm.buf)


class SharedTensorManager:
    def __init__(self, name, size) -> None:
        self.name = name
        self.size = size
        self.shape_infs = SharedArray(f"{name}_shapes", (size, 2), dtype=np.int32)
        self.tensors = [None for _ in range(size)]
        return
    
    def set_index_data(self, index, shape, data, dtype):
        shm_arr = SharedArray(f"{self.name}_{index}_tensor", shape, dtype=dtype)
        shm_arr.arr[:, :] = data
        self.shape_infs.arr[index,:] = shape
        self.tensors[index] = shm_arr
        return
    
    def get_index_tensor_shape(self, index):
        return tuple(self.shape_infs.arr[index])
    
    def get_index_tensor(self, index, dtype):
        shape = self.get_index_tensor_shape(index)
        shm_arr = SharedArray(f"{self.name}_{index}_tensor", shape, dtype=dtype)
        self.tensors[index] = shm_arr
        return shm_arr
    
    # def release(self, index):
    #     shape = self.get_index_tensor_shape(index)
    #     shm_arr = SharedArray(f"{self.name}_{index}_tensor", shape, dtype=np.float16)
    #     shm_arr.shm.unlink() # 销毁shm。
    #     shm_arr.shm.close()
    #     logger.info(f"release shm tensor index {index}")
    #     return


class SharedSpeechManager:
    def __init__(self, name, size, init_mark=True, preset_slots=30) -> None:
        """
        初始化共享内存管理器

        Args:
            name: 共享内存名称前缀
            size: 总槽位数
            init_mark: 是否初始化标记
            preset_slots: 预设音色固定槽位数 (默认 10)
                         预设音色使用 [0, preset_slots), 动态上传使用 [preset_slots, size)
        """
        self.name = name
        self.size = size
        self.preset_slots = preset_slots
        self.dynamic_slots = size - preset_slots

        self.use_marks = SharedArray(f"{name}_use_marks", (size,), dtype=np.int32)
        if init_mark:
            self.use_marks.arr[:] = 0
        self.lru_cache = OrderedDict()
        self.lock = threading.Lock()

        # 预设音色映射: spk_id → 固定槽位 [0, preset_slots)
        self.spk_id_to_index = {}

        self.prompt_speech_16k_manager = SharedTensorManager(f"{name}_prompt_speech_16k", size)
        self.speech_feat_manager = SharedTensorManager(f"{name}_speech_feat", size)
        self.speech_token_manager = SharedTensorManager(f"{name}_speech_token", size)
        self.spk_embedding_manager = SharedTensorManager(f"{name}_spk_embedding", size)
        return
        
    
    def alloc(self, speech_md5):
        """
        动态上传模式分配共享内存 (仅使用 [preset_slots, size) 槽位)

        Args:
            speech_md5: 音频 MD5 哈希

        Returns:
            (index, have_alloc): index=共享内存索引, have_alloc=是否已缓存
        """
        with self.lock:
            # 检查缓存
            if speech_md5 in self.lru_cache:
                self.lru_cache.move_to_end(speech_md5)
                return self.lru_cache[speech_md5], True

            # 新分配: 只在动态槽位范围 [preset_slots, size) 内查找
            index = None
            if len(self.lru_cache) >= self.dynamic_slots:
                # 动态槽位 LRU 已满,驱逐最久未使用的项
                key, value = self.lru_cache.popitem(last=False)
                index = value
                # 重置状态为已分配 (后续 set_index_data 会更新为 2)
                self.use_marks.arr[index] = 1
            else:
                # 在动态槽位范围 [preset_slots, size) 内查找空闲槽位
                for i in range(self.preset_slots, self.size):
                    if self.use_marks.arr[i] == 0:
                        index = i
                        break

            if index is None:
                raise RuntimeError(f"alloc failed: no available slot in dynamic range [{self.preset_slots}, {self.size})")

            self.use_marks.arr[index] = 1
            self.lru_cache[speech_md5] = index
            return index, False

    def alloc_by_spk_id(self, spk_id):
        """
        通过 spk_id 分配共享内存 (预设音色快速路径)

        使用固定槽位 [0, preset_slots), 不参与 LRU 驱逐

        Args:
            spk_id: 音色 ID

        Returns:
            (index, have_alloc): index=共享内存索引, have_alloc=是否已缓存
        """
        with self.lock:
            # 检查 spk_id 是否已映射
            if spk_id in self.spk_id_to_index:
                index = self.spk_id_to_index[spk_id]
                return index, True  # 命中缓存

            # 未映射,在预设槽位范围 [0, preset_slots) 内分配新索引
            # 注意: 不检查 LRU,预设音色不参与驱逐
            if len(self.spk_id_to_index) >= self.preset_slots:
                raise RuntimeError(
                    f"alloc_by_spk_id failed: preset slots full ({self.preset_slots}), "
                    f"cannot register spk_id='{spk_id}'. "
                    f"Consider increasing --preset-slots parameter."
                )

            # 在预设槽位范围 [0, preset_slots) 内查找空闲槽位
            index = None
            for i in range(self.preset_slots):
                if self.use_marks.arr[i] == 0:
                    index = i
                    break

            if index is None:
                # 理论上不应该到达这里 (前面已经检查了数量)
                raise RuntimeError(f"alloc_by_spk_id failed: no available slot in preset range [0, {self.preset_slots})")

            # 标记为已分配
            self.use_marks.arr[index] = 1
            # 建立映射 (不加入 LRU,预设音色固定槽位)
            self.spk_id_to_index[spk_id] = index

            return index, False  # 新分配

    def set_index_data(self, index, shape, data):
        self.prompt_speech_16k_manager.set_index_data(index, shape, data, np.float32)
        self.use_marks.arr[index] = 2
        return

    def get_index_data(self, index):
        if self.use_marks.arr[index] >= 2:
            return self.prompt_speech_16k_manager.get_index_tensor(index, dtype=np.float32)
        return None

    def set_index_speech(self, index, speech_token, speech_feat, spk_embedding):
        self.speech_token_manager.set_index_data(index, speech_token.shape, speech_token, np.int32)
        self.speech_feat_manager.set_index_data(index, speech_feat.shape, speech_feat, np.float32)
        self.spk_embedding_manager.set_index_data(index, spk_embedding.shape, spk_embedding, np.float32)
        self.use_marks.arr[index] = 3
        return

    def get_index_speech_token(self, index):
        if self.use_marks.arr[index] >= 3:
            return self.speech_token_manager.get_index_tensor(index, dtype=np.int32)
        return None

    def get_index_speech(self, index):
        if self.use_marks.arr[index] >= 3:
            return self.speech_token_manager.get_index_tensor(index, dtype=np.int32), self.speech_feat_manager.get_index_tensor(index, dtype=np.float32), self.spk_embedding_manager.get_index_tensor(index, np.float32)
        return None

    def speech_data_ready(self, index):
        if self.use_marks.arr[index] >= 3:
            return True
        return False